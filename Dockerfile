ARG RUBY_VERSION=3.3.0
FROM ruby:$RUBY_VERSION-slim AS base

# Rack app lives here
WORKDIR /app

# development / test グループの gem は本番イメージに入れない。
# base に置くことで build ステージの bundle install と最終イメージの bundle exec の
# 両方に効き、テスト用 gem 無しでも起動できる状態を保つ。
# BUNDLE_FROZEN は Gemfile.lock を書き換えさせず、Gemfile とずれていればビルドを失敗させる。
# （インストール先を変えてしまう BUNDLE_DEPLOYMENT は使わない。下の
#  COPY --from=build /usr/local/bundle と衝突するため）
ENV BUNDLE_WITHOUT="development:test" \
    BUNDLE_FROZEN="true"

# Update gems and bundler
RUN gem update --system --no-document && \
    gem install -N bundler


# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential

# Install application gems
COPY Gemfile* .
RUN bundle install


# ----------------------------------------------------------------
# テストステージ。ここが失敗するとイメージが作られない = デプロイされない。
#
# ビルドに内包しているのは、ローカルの `fly deploy` が git を経由せず
# 作業ディレクトリをそのまま送るため。pre-push フックも GitHub Actions も
# すり抜けるので、イメージを作る経路そのものに関門を置いている。
# ----------------------------------------------------------------
FROM build AS test

# base で development:test を除外しているので、テスト用 gem のために打ち消す。
# build ステージの bundle install が /usr/local/bundle/config に without を
# 永続化しているため、環境変数を空にするだけでは足りず config 側の解除も要る。
ENV BUNDLE_WITHOUT=""
RUN bundle config unset without && \
    bundle install

COPY . .

# 外部APIに接続する rake test_live は含めない。
# ネットワーク障害や相手側の仕様変更でデプロイできなくなるのを避けるため。
RUN bundle exec rake test && touch /tmp/tests-passed


# Final stage for app image
FROM base

# Run and own the application files as a non-root user for security
RUN useradd ruby --home /app --shell /bin/bash
USER ruby:ruby

# Copy built artifacts: gems, application
# gem は build から取る（test ステージの development:test グループを持ち込まないため）
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=ruby:ruby /app /app

# test ステージへの依存。これが無いと BuildKit がテストを丸ごとスキップする
COPY --from=test /tmp/tests-passed /tmp/tests-passed

# Copy application code
# 実行に必要なものだけを明示的に入れる（test/ や Rakefile は本番イメージに含めない）
COPY --chown=ruby:ruby main.rb ./
COPY --chown=ruby:ruby lib ./lib
COPY --chown=ruby:ruby data ./data

# Start the bot
CMD ["bundle", "exec", "ruby", "main.rb"]
