# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

Rake::TestTask.new("test:blog") do |task|
  task.libs << "lib"
  task.pattern = "examples/blog/test/**/*_test.rb"
end

Rake::TestTask.new("test:todomvc") do |task|
  task.libs << "lib"
  task.pattern = "examples/todomvc/test/**/*_test.rb"
end

Rake::TestTask.new("test:workouts") do |task|
  task.libs << "lib"
  task.pattern = "examples/workouts/test/**/*_test.rb"
end

Rake::TestTask.new("test:site") do |task|
  task.libs << "lib"
  task.pattern = "examples/site/test/**/*_test.rb"
end

task default: [:test, "test:blog", "test:todomvc", "test:workouts", "test:site"]

desc "Run the JavaScript navigation tests"
task "test:client" do
  sh "npm run test:client"
end

desc "Run the browser navigation smoke tests"
task "test:browser" do
  sh "npm run test:browser"
end
