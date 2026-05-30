#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "optparse"
require "pathname"
require "fileutils"
require "pty"
require "shellwords"
require "uri"
require "io/console"

WORKSPACE_DIR = Pathname.new(ENV.fetch("WORKSPACE_DIR", File.expand_path("../..", __dir__)))
BUMP_PLAN_SCRIPT = WORKSPACE_DIR.join("meta", "scripts", "release_bump_plan.rb")
TMPDIR_PATH = Pathname.new(ENV.fetch("TMPDIR", WORKSPACE_DIR.join("tmp").to_s))
DEFAULT_BUMP_PLAN_JSON = TMPDIR_PATH.join("release_bump_plan.json")

REPO_RELEASE_ORDER = %w[
  standard-rubocop-lts
  rubocop-lts-rspec
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
].freeze

RUBOCOP_LTS_BRANCH_RELEASE_ORDER = %w[
  r1_8-even-v0
  r1_9-even-v2
  r2_0-even-v4
  r2_1-even-v6
  r2_2-even-v8
  r2_3-even-v10
  r2_4-even-v12
  r2_5-even-v14
  r2_6-even-v16
  r2_7-even-v18
  r3_0-even-v20
  r3_1-even-v22
  r3_2-even-v24
  main
].freeze

PROMPT_SIGNING = /pass\s*(?:phrase|word)|signing key|private key/i
PROMPT_OTP = /otp|multi-factor|mfa/i

options = {
  push: false,
  push_git: false,
  tag: false,
  require_tags: false,
  include_main: false,
  prepare: true,
  bundle_install: true,
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

  opts.on("--include-main", "Include rubocop-lts@main in release queue (off by default)") do
    options[:include_main] = true
  end

  opts.on("--[no-]prepare", "Run mise/bundler preparation before build/release (default: enabled)") do |value|
    options[:prepare] = value
  end

  opts.on("--json FILE", "Use an existing bump-plan JSON file instead of regenerating #{DEFAULT_BUMP_PLAN_JSON}") do |file|
    options[:json_path] = Pathname.new(File.expand_path(file))
  end

  opts.on("--[no-]bundle-install", "Run bundle install before tests/build/release (default: enabled)") do |value|
    options[:bundle_install] = value
  end

  opts.on("--skip-tests", "Skip bundle exec rake spec") do
    options[:skip_tests] = true
  end

  opts.on("--only TARGET", "Release only one repo or all rubocop-lts branches via rubocop-lts / rubocop-lts@branch") do |repo|
    options[:only] = repo
  end

  opts.on("--start-at TARGET", "Start from repo or rubocop-lts@branch in release order") do |repo|
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

def run_or_echo!(cmd, chdir:, execute:)
  if execute
    run!(cmd, chdir: chdir)
  else
    puts "DRY-RUN: #{sh(cmd)}"
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

def git_dirty?(repo_dir)
  !capture!(["git", "status", "--porcelain"], chdir: repo_dir).empty?
end

def current_branch(repo)
  repo_dir = WORKSPACE_DIR.join(repo)
  capture!(["git", "branch", "--show-current"], chdir: repo_dir).strip
end

def checkout_ref!(repo, ref, execute:)
  cmd = ["git", "checkout", ref]
  repo_dir = WORKSPACE_DIR.join(repo)
  if execute
    run!(cmd, chdir: repo_dir)
  else
    puts "DRY-RUN: #{sh(cmd)}"
  end
end

def push_current_ref!(repo_dir, target_name, execute:)
  branch = capture!(["git", "branch", "--show-current"], chdir: repo_dir).strip
  upstream = capture!(["git", "rev-parse", "--abbrev-ref", "#{branch}@{upstream}"], chdir: repo_dir).strip
  remote = upstream.split("/", 2).fetch(0)
  remote_branch = upstream.split("/", 2).fetch(1)
  cmd = ["git", "push", remote, "#{branch}:#{remote_branch}"]

  if execute
    run!(cmd, chdir: repo_dir)
  else
    puts "DRY-RUN: #{sh(cmd)} # #{target_name}"
  end
end

def commit_prepare_changes!(repo_dir, target_name, version, execute:, push_git:)
  return unless git_dirty?(repo_dir)

  message = "Update release preparation for #{target_name} #{version}"
  if execute
    run!(["git", "add", "-A"], chdir: repo_dir)
    run!(["git", "commit", "-m", message], chdir: repo_dir)
    push_current_ref!(repo_dir, target_name, execute: true) if push_git
  else
    puts "DRY-RUN: git add -A"
    puts "DRY-RUN: git commit -m #{message.shellescape}"
    push_current_ref!(repo_dir, target_name, execute: false) if push_git
  end
end

def prepare_release_target!(repo_dir, execute:)
  [
    ["mise", "use", "ruby@4.0.5"],
    ["mise", "trust", "mise.toml"],
    ["bundle", "update"],
    ["bundle", "update", "--bundler"]
  ].each do |cmd|
    run_or_echo!(cmd, chdir: repo_dir, execute: execute)
  end
end

def load_bump_plan_json!(json_path)
  raise "Missing bump-plan JSON file: #{json_path}" unless json_path.exist?

  JSON.parse(json_path.read)
rescue JSON::ParserError => e
  raise "bump plan did not return valid JSON: #{e.message}"
end

def ensure_bump_plan_json!(require_tags:, json_path: nil)
  return [load_bump_plan_json!(json_path), json_path] if json_path

  raise "Missing bump plan script: #{BUMP_PLAN_SCRIPT}" unless BUMP_PLAN_SCRIPT.exist?

  FileUtils.mkdir_p(TMPDIR_PATH)
  FileUtils.rm_f(DEFAULT_BUMP_PLAN_JSON)

  cmd = [BUMP_PLAN_SCRIPT.to_s, "--json"]
  cmd << "--require-tags" if require_tags

  output, status = Open3.capture2e(*cmd, chdir: WORKSPACE_DIR)
  DEFAULT_BUMP_PLAN_JSON.write(output)
  parsed = load_bump_plan_json!(DEFAULT_BUMP_PLAN_JSON)

  if !status.success? && require_tags
    raise "bump plan reported blocking failures in strict mode"
  end

  [parsed, DEFAULT_BUMP_PLAN_JSON]
end

def apply_selection(repos, options)
  selected = repos.dup

  if options[:only]
    selected.select! do |target|
      target_key(target) == options[:only] || (options[:only] == "rubocop-lts" && target.fetch(:repo) == "rubocop-lts")
    end
    raise "Unknown repo for --only: #{options[:only]}" if selected.empty?
  end

  if options[:start_at]
    idx = selected.index do |target|
      target_key(target) == options[:start_at] || (options[:start_at] == "rubocop-lts" && target.fetch(:repo) == "rubocop-lts")
    end
    raise "Unknown repo for --start-at: #{options[:start_at]}" unless idx

    selected = selected.drop(idx)
  end

  selected
end

def target_key(target)
  target.fetch(:name)
end

def build_release_targets(plan, include_main: false)
  repo_targets = plan.fetch("repo_bump_audit")
                .select { |row| row.fetch("repo") != "rubocop-lts" }
                .select { |row| row.fetch("commits").to_i > 0 }
                .reject { |row| row.fetch("status") == "FAIL" }
                .map do |row|
                  repo = row.fetch("repo")
                  {
                    type: :repo,
                    repo: repo,
                    name: repo,
                    version: repo_version(repo),
                    gem_name: gemspec_name(repo)
                  }
                end

  branch_targets = plan.fetch("rubocop_lts_branch_audit")
                  .reject { |row| row.fetch("branch") == "main" && !include_main }
                  .select do |row|
                    row.fetch("head_tag_exists") == false || row.fetch("commits_past_head_tag").to_i > 0
                  end
                  .reject { |row| row.fetch("status") == "FAIL" }
                  .map do |row|
                    branch = row.fetch("branch")
                    {
                      type: :branch,
                      repo: "rubocop-lts",
                      ref: branch,
                      name: "rubocop-lts@#{branch}",
                      version: row.fetch("head_version"),
                      gem_name: gemspec_name("rubocop-lts")
                    }
                  end

  ordered_repo_targets = REPO_RELEASE_ORDER.filter_map do |repo|
    repo_targets.find { |target| target.fetch(:repo) == repo }
  end

  ordered_branch_targets = RUBOCOP_LTS_BRANCH_RELEASE_ORDER.filter_map do |branch|
    branch_targets.find { |target| target.fetch(:ref) == branch }
  end

  ordered_repo_targets + ordered_branch_targets
end

plan, bump_plan_json_path = ensure_bump_plan_json!(
  require_tags: options[:require_tags],
  json_path: options[:json_path]
)
release_queue = build_release_targets(plan, include_main: options[:include_main])
release_queue = apply_selection(release_queue, options)

if release_queue.empty?
  puts "No repos with commits since tag from bump plan. Nothing to publish."
  exit 0
end

puts "release_publish workspace=#{WORKSPACE_DIR}"
puts "bump_plan_json=#{bump_plan_json_path}"
puts "mode=#{options[:execute] ? (options[:push] ? "execute+push" : "execute+build") : "dry-run"}"
puts "prepare=#{options[:prepare]}"
puts "bundle_install=#{options[:bundle_install]}"
puts "queue=#{release_queue.map { |target| target_key(target) }.join(", ")}"

signing_key_passphrase = nil
original_rubocop_lts_branch = nil
failed_target = nil

begin
  failed_target = "preflight"
  release_queue.map { |target| target.fetch(:repo) }.uniq.each { |repo| ensure_clean_git!(repo) }

  if options[:push_git] && (!options[:push] || !options[:execute])
    raise "--push-git requires --execute --push"
  end

  if options[:tag] && !options[:execute]
    raise "--tag requires --execute"
  end

  if options[:execute] && options[:push]
    print "Gem signing key passphrase: "
    signing_key_passphrase = STDIN.noecho(&:gets)&.chomp.to_s
    puts
    raise "Gem signing key passphrase cannot be empty" if signing_key_passphrase.empty?
  end

  original_rubocop_lts_branch = current_branch("rubocop-lts") if release_queue.any? { |target| target.fetch(:repo) == "rubocop-lts" }

  release_queue.each do |target|
    repo = target.fetch(:repo)
    repo_dir = WORKSPACE_DIR.join(repo)
    version = target.fetch(:version)
    gem_name = target.fetch(:gem_name)
    target_name = target_key(target)
    failed_target = target_name

    puts "\n=== #{target_name} #{version} ==="

    if options[:push] && rubygems_version_released?(gem_name, version)
      puts "Skipping #{gem_name} #{version}; already released on RubyGems."
      failed_target = nil
      next
    end

    if target[:type] == :branch
      checkout_ref!(repo, target.fetch(:ref), execute: options[:execute])
    end

    if options[:prepare]
      prepare_release_target!(repo_dir, execute: options[:execute])
    end

    if options[:bundle_install]
      # Ensure git/path sources in Gemfile/Gemfile.lock are resolved before rake tasks.
      run_or_echo!(["bundle", "install"], chdir: repo_dir, execute: options[:execute])
    end

    commit_prepare_changes!(
      repo_dir,
      target_name,
      version,
      execute: options[:execute],
      push_git: options[:push_git]
    )

    if options[:skip_tests]
      puts "Skipping tests for #{target_name}"
    else
      spec_dir = repo_dir.join("spec")
      if spec_dir.exist?
        cmd = ["bundle", "exec", "rake", "spec"]
        run_or_echo!(cmd, chdir: repo_dir, execute: options[:execute])
      else
        puts "No spec directory in #{target_name}; skipping tests"
      end
    end

    if options[:push]
      cmd = ["bundle", "exec", "rake", "release"]
      if options[:execute]
        run_with_auth!(cmd, chdir: repo_dir, signing_key_passphrase: signing_key_passphrase)
        run!(["gem", "info", gem_name, "--remote", "-v", version], chdir: repo_dir)
      else
        run_or_echo!(cmd, chdir: repo_dir, execute: false)
      end
    else
      cmd = ["bundle", "exec", "rake", "build"]
      run_or_echo!(cmd, chdir: repo_dir, execute: options[:execute])
    end

    next unless options[:tag]

    tag_name = "v#{version}"
    tag_exists = system("git", "rev-parse", "-q", "--verify", "refs/tags/#{tag_name}", chdir: repo_dir,
      out: File::NULL, err: File::NULL)
    unless tag_exists
      cmd = ["git", "tag", "-a", tag_name, "-m", "Release #{target_name} #{version}"]
      run_or_echo!(cmd, chdir: repo_dir, execute: options[:execute])
    end

    next unless options[:push_git]

    options[:execute] ? run!(["git", "push", "origin", "HEAD"], chdir: repo_dir) : puts("DRY-RUN: git push origin HEAD")
    options[:execute] ? run!(["git", "push", "origin", tag_name], chdir: repo_dir) : puts("DRY-RUN: git push origin #{tag_name}")
    failed_target = nil
  end
rescue StandardError => e
  warn "\nrelease_publish failed at #{failed_target || "startup"}: #{e.message}"
  exit 1
ensure
  if original_rubocop_lts_branch
    puts "\n=== restore rubocop-lts branch ==="
    checkout_ref!("rubocop-lts", original_rubocop_lts_branch, execute: options[:execute])
  end
end

puts "\nrelease_publish complete"
