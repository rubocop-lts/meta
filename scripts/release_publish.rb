#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "optparse"
require "pathname"
require "pty"
require "shellwords"
require "uri"
require "io/console"

WORKSPACE_DIR = Pathname.new(ENV.fetch("WORKSPACE_DIR", File.expand_path("../..", __dir__)))
BUMP_PLAN_SCRIPT = WORKSPACE_DIR.join("meta", "scripts", "release_bump_plan.rb")

RELEASE_ORDER = %w[
  rubocop-ruby1_8
  rubocop-ruby1_9
  rubocop-ruby2_0
  rubocop-ruby2_1
  rubocop-ruby2_2
  rubocop-ruby2_3
  rubocop-ruby2_4
  rubocop-ruby2_5
  rubocop-ruby2_6
  rubocop-ruby2_7
  rubocop-ruby3_0
  rubocop-ruby3_1
  rubocop-ruby3_2
  standard-rubocop-lts
  rubocop-lts-rspec
  rubocop-lts
].freeze

PROMPT_SIGNING = /pass\s*(?:phrase|word)|signing key|private key/i
PROMPT_OTP = /otp|multi-factor|mfa/i

options = {
  push: false,
  push_git: false,
  tag: false,
  require_tags: false,
  skip_tests: false,
  execute: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: release_publish.rb [options]"

  opts.on("--execute", "Run commands (default is dry-run preview only)") do
    options[:execute] = true
  end

  opts.on("--push", "Upload gems via `rake release` (requires --execute)") do
    options[:push] = true
  end

  opts.on("--no-push", "Build gems locally only (default)") do
    options[:push] = false
  end

  opts.on("--push-git", "After release, push branch and tags (requires --execute --push)") do
    options[:push_git] = true
  end

  opts.on("--tag", "Create missing vVERSION tags before optional git push") do
    options[:tag] = true
  end

  opts.on("--require-tags", "Run bump-plan in strict tag mode") do
    options[:require_tags] = true
  end

  opts.on("--skip-tests", "Skip bundle exec rake spec") do
    options[:skip_tests] = true
  end

  opts.on("--only REPO", "Release only one repo from release order") do |repo|
    options[:only] = repo
  end

  opts.on("--start-at REPO", "Start from repo in release order") do |repo|
    options[:start_at] = repo
  end

  opts.on("-h", "--help", "Show help") do
    puts opts
    exit 0
  end
end.parse!

def sh(cmd)
  Shellwords.join(cmd)
end

def capture!(cmd, chdir:)
  out, status = Open3.capture2e(*cmd, chdir: chdir)
  raise "Command failed: #{sh(cmd)}\n#{out}" unless status.success?

  out
end

def run!(cmd, chdir:)
  puts "\n$ #{sh(cmd)}"
  ok = system(*cmd, chdir: chdir)
  raise "Command failed: #{sh(cmd)}" unless ok
end

def run_with_auth!(cmd, chdir:, signing_key_passphrase:)
  puts "\n$ #{sh(cmd)}"
  PTY.spawn(*cmd, chdir: chdir) do |reader, writer, pid|
    begin
      loop do
        chunk = reader.readpartial(4096)
        print chunk

        if chunk.match?(PROMPT_SIGNING)
          writer.write(signing_key_passphrase)
          writer.write("\n")
          next
        end

        next unless chunk.match?(PROMPT_OTP)

        print "RubyGems MFA OTP: "
        otp = STDIN.gets&.chomp.to_s
        raise "RubyGems MFA OTP cannot be empty" if otp.empty?

        writer.write(otp)
        writer.write("\n")
      end
    rescue EOFError, Errno::EIO
      # PTY closes like this on multiple platforms.
    ensure
      writer.close unless writer.closed?
    end

    _pid, status = Process.wait2(pid)
    raise "Command failed: #{sh(cmd)}" unless status.success?
  end
end

def rubygems_version_released?(name, version)
  uri = URI("https://rubygems.org/api/v1/versions/#{URI.encode_www_form_component(name)}.json")
  response = Net::HTTP.get_response(uri)
  return false if response.is_a?(Net::HTTPNotFound)

  unless response.is_a?(Net::HTTPSuccess)
    raise "Could not check RubyGems state for #{name}: HTTP #{response.code}"
  end

  JSON.parse(response.body).any? { |entry| entry.fetch("number") == version }
end

def parse_version_rb(content)
  content[/VERSION\s*=\s*"([^"]+)"/, 1]
end

def repo_version(repo)
  version_file = Dir[WORKSPACE_DIR.join(repo, "lib", "**", "version.rb")].first
  raise "No version.rb found in #{repo}" unless version_file

  version = parse_version_rb(File.read(version_file))
  raise "Could not parse version in #{repo}" unless version

  version
end

def gemspec_name(repo)
  gemspec = Dir[WORKSPACE_DIR.join(repo, "*.gemspec")].first
  raise "No gemspec found in #{repo}" unless gemspec

  File.basename(gemspec, ".gemspec")
end

def ensure_clean_git!(repo)
  repo_dir = WORKSPACE_DIR.join(repo)
  status = capture!(["git", "status", "--porcelain"], chdir: repo_dir)
  raise "#{repo} has uncommitted changes\n#{status}" unless status.empty?
end

def ensure_bump_plan_json!(require_tags:)
  raise "Missing bump plan script: #{BUMP_PLAN_SCRIPT}" unless BUMP_PLAN_SCRIPT.exist?

  cmd = [BUMP_PLAN_SCRIPT.to_s, "--json"]
  cmd << "--require-tags" if require_tags

  output, status = Open3.capture2e(*cmd, chdir: WORKSPACE_DIR)
  parsed = JSON.parse(output)

  if !status.success? && require_tags
    raise "bump plan reported blocking failures in strict mode"
  end

  parsed
rescue JSON::ParserError => e
  raise "bump plan did not return valid JSON: #{e.message}"
end

def apply_selection(repos, options)
  selected = repos.dup

  if options[:only]
    selected.select! { |repo| repo == options[:only] }
    raise "Unknown repo for --only: #{options[:only]}" if selected.empty?
  end

  if options[:start_at]
    idx = selected.index(options[:start_at])
    raise "Unknown repo for --start-at: #{options[:start_at]}" unless idx

    selected = selected.drop(idx)
  end

  selected
end

plan = ensure_bump_plan_json!(require_tags: options[:require_tags])
repo_rows = plan.fetch("repo_bump_audit")

pending = repo_rows
          .select { |row| row.fetch("commits").to_i > 0 }
          .map { |row| row.fetch("repo") }

release_queue = RELEASE_ORDER.select { |repo| pending.include?(repo) }
release_queue = apply_selection(release_queue, options)

if release_queue.empty?
  puts "No repos with commits since tag from bump plan. Nothing to publish."
  exit 0
end

puts "release_publish workspace=#{WORKSPACE_DIR}"
puts "mode=#{options[:execute] ? (options[:push] ? "execute+push" : "execute+build") : "dry-run"}"
puts "queue=#{release_queue.join(", ")}"

release_queue.each { |repo| ensure_clean_git!(repo) }

if options[:push_git] && (!options[:push] || !options[:execute])
  raise "--push-git requires --execute --push"
end

if options[:tag] && !options[:execute]
  raise "--tag requires --execute"
end

signing_key_passphrase = nil
if options[:execute] && options[:push]
  print "Gem signing key passphrase: "
  signing_key_passphrase = STDIN.noecho(&:gets)&.chomp.to_s
  puts
  raise "Gem signing key passphrase cannot be empty" if signing_key_passphrase.empty?
end

release_queue.each do |repo|
  repo_dir = WORKSPACE_DIR.join(repo)
  version = repo_version(repo)
  gem_name = gemspec_name(repo)

  puts "\n=== #{repo} #{version} ==="

  if options[:push] && rubygems_version_released?(gem_name, version)
    puts "Skipping #{gem_name} #{version}; already released on RubyGems."
    next
  end

  if options[:skip_tests]
    puts "Skipping tests for #{repo}"
  else
    spec_dir = repo_dir.join("spec")
    if spec_dir.exist?
      cmd = ["bundle", "exec", "rake", "spec"]
      options[:execute] ? run!(cmd, chdir: repo_dir) : puts("DRY-RUN: #{sh(cmd)}")
    else
      puts "No spec directory in #{repo}; skipping tests"
    end
  end

  if options[:push]
    cmd = ["bundle", "exec", "rake", "release"]
    if options[:execute]
      run_with_auth!(cmd, chdir: repo_dir, signing_key_passphrase: signing_key_passphrase)
      run!(["gem", "info", gem_name, "--remote", "-v", version], chdir: repo_dir)
    else
      puts "DRY-RUN: #{sh(cmd)}"
    end
  else
    cmd = ["bundle", "exec", "rake", "build"]
    options[:execute] ? run!(cmd, chdir: repo_dir) : puts("DRY-RUN: #{sh(cmd)}")
  end

  next unless options[:tag]

  tag_name = "v#{version}"
  tag_exists = system("git", "rev-parse", "-q", "--verify", "refs/tags/#{tag_name}", chdir: repo_dir,
    out: File::NULL, err: File::NULL)
  unless tag_exists
    cmd = ["git", "tag", "-a", tag_name, "-m", "Release #{repo} #{version}"]
    options[:execute] ? run!(cmd, chdir: repo_dir) : puts("DRY-RUN: #{sh(cmd)}")
  end

  next unless options[:push_git]

  options[:execute] ? run!(["git", "push", "origin", "HEAD"], chdir: repo_dir) : puts("DRY-RUN: git push origin HEAD")
  options[:execute] ? run!(["git", "push", "origin", tag_name], chdir: repo_dir) : puts("DRY-RUN: git push origin #{tag_name}")
end

puts "\nrelease_publish complete"
