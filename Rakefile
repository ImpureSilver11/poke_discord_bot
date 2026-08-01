require 'bundler/setup'
require 'rake/testtask'

# 既定のテスト。外部APIには接続しない。
Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.warning    = false
end

# 実 tcgdex API への疎通も含めて実行する。CI では既定で走らせない。
desc '外部APIへの疎通テストも含めて実行する'
task :test_live do
  ENV['LIVE'] = '1'
  Rake::Task[:test].invoke
end

task default: :test
