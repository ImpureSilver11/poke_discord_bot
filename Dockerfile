ARG RUBY_VERSION=3.3.0
FROM ruby:$RUBY_VERSION-slim as base

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
FROM base as build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential

# Install application gems
COPY Gemfile* .
RUN bundle install


# Final stage for app image
FROM base

# Run and own the application files as a non-root user for security
RUN useradd ruby --home /app --shell /bin/bash
USER ruby:ruby

# Copy built artifacts: gems, application
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=ruby:ruby /app /app

# Copy application code
COPY --chown=ruby:ruby . .

# Start the bot
CMD ["bundle", "exec", "ruby", "main.rb"]
