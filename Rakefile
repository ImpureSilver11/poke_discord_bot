require 'bundler/setup'
require 'rake/testtask'

# 外部APIに接続するテストは別ファイル（test/test_*_live.rb）に分けている。
# 既定の rake test からは除外して、skip が 0 件＝常に全部通る状態を保つ。
OFFLINE_TESTS = FileList['test/test_*.rb'].exclude('test/test_*_live.rb')
LIVE_TESTS    = FileList['test/test_*_live.rb']

desc '外部APIに接続しないテスト（既定）'
Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = OFFLINE_TESTS
  t.warning    = false
end

desc '外部APIへの疎通テストのみ実行する'
Rake::TestTask.new(:test_live) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = LIVE_TESTS
  t.warning    = false
end
# LIVE=1 が無いと live テストは自分で skip するため、タスク側で必ず立てる
task :test_live => :set_live_env
task :set_live_env do
  ENV['LIVE'] = '1'
end

desc 'オフライン + 疎通テストを両方実行する'
task test_all: %i[test test_live]

namespace :hooks do
  HOOKS_DIR = '.githooks'.freeze

  desc "git のフックを #{HOOKS_DIR} に向ける（push 前に rake test を実行する）"
  task :install do
    sh "git config core.hooksPath #{HOOKS_DIR}"
    puts "インストールしました。push 前に #{OFFLINE_TESTS.size} ファイルのテストが走ります。"
    puts '解除するには rake hooks:uninstall'
  end

  desc 'git のフック設定を解除する'
  task :uninstall do
    sh 'git config --unset core.hooksPath'
    puts '解除しました。'
  end
end

task default: :test
