#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require "rubygems"

WORKSPACE_DIR = Pathname.new(ENV.fetch("WORKSPACE_DIR", File.expand_path("../..", __dir__)))
REQUIRE_TAGS_DEFAULT = ENV.fetch("REQUIRE_TAGS", "false") == "true"

REPOS = %w[
  rubocop-lts
  rubocop-lts-rspec
  standard-rubocop-lts
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

RUBOCOP_LTS_BRANCHES = {
  "main" => "rubocop-ruby3_2",
  "r1_8-even-v0" => "rubocop-ruby1_8",
  "r1_9-even-v2" => "rubocop-ruby1_9",
  "r2_0-even-v4" => "rubocop-ruby2_0",
  "r2_1-even-v6" => "rubocop-ruby2_1",
  "r2_2-even-v8" => "rubocop-ruby2_2",
  "r2_3-even-v10" => "rubocop-ruby2_3",
  "r2_4-even-v12" => "rubocop-ruby2_4",
  "r2_5-even-v14" => "rubocop-ruby2_5",
  "r2_6-even-v16" => "rubocop-ruby2_6",
  "r2_7-even-v18" => "rubocop-ruby2_7",
  "r3_0-even-v20" => "rubocop-ruby3_0",
  "r3_1-even-v22" => "rubocop-ruby3_1",
  "r3_2-even-v24" => "rubocop-ruby3_2"
}.freeze

BUMP_RANK = { "none" => 0, "patch" => 1, "minor" => 2, "major" => 3 }.freeze

def parse_args(argv)
  require_tags = REQUIRE_TAGS_DEFAULT

  argv.each do |arg|
    case arg
    when "--require-tags"
      require_tags = true
    when "-h", "--help"
      puts <<~USAGE
        Usage: release_bump_plan.rb [options]

        Options:
          --require-tags   Enforce tag-dependent checks as failures
          -h, --help       Show this help

        Environment:
          WORKSPACE_DIR    Workspace root (defaults to parent of meta)
          REQUIRE_TAGS     true/false (same effect as --require-tags)
      USAGE
      exit 0
    else
      warn "Unknown option: #{arg}"
      exit 2
    end
  end

  require_tags
end

RepoReport = Struct.new(
  :repo,
  :head_version,
  :tag_version,
  :previous_tag,
  :previous_tag_version,
  :latest_tag,
  :commits_since_tag,
  :required_bump,
  :actual_bump,
  :latest_release_required_bump,
  :latest_release_actual_bump,
  :latest_release_reasons,
  :major_correction_needed,
  :reasons,
  :next_major,
  keyword_init: true
)


def run_cmd(*argv, chdir: nil)
  stdout, stderr, status = Open3.capture3(*argv, chdir: chdir)
  raise "#{argv.join(" ")} failed: #{stderr.strip}" unless status.success?

  stdout
end


def safe_cmd(*argv, chdir: nil)
  stdout, stderr, status = Open3.capture3(*argv, chdir: chdir)
  [stdout, stderr, status.success?]
end


def parse_version_rb(content)
  content[/VERSION\s*=\s*"([^"]+)"/, 1]
end


def parse_required_ruby_min(gemspec)
  raw = gemspec[/required_ruby_version\s*=\s*"([^"]+)"/, 1]
  return nil unless raw

  min = raw[/>=\s*([0-9]+(?:\.[0-9]+){0,2})/, 1]
  return nil unless min

  Gem::Version.new(min)
end


def parse_dependency_bounds(gemspec, dep_name)
  line = gemspec.lines.find { |ln| ln.include?("add_dependency(\"#{dep_name}\"") }
  return [nil, nil] unless line

  lower = line[/>=\s*([0-9]+(?:\.[0-9]+){0,2})/, 1]
  lower ||= line[/~>\s*([0-9]+(?:\.[0-9]+){0,2})/, 1]

  upper = line[/<\s*([0-9]+(?:\.[0-9]+){0,2})/, 1]

  [lower ? Gem::Version.new(lower) : nil, upper ? Gem::Version.new(upper) : nil]
end


def semver_bump(old_v, new_v)
  return "none" if old_v == new_v

  old_parts = old_v.split(".").map(&:to_i)
  new_parts = new_v.split(".").map(&:to_i)

  return "major" if new_parts[0] > old_parts[0]
  return "minor" if new_parts[1] > old_parts[1]

  "patch"
end


def required_bump_for(repo, reasons)
  return "patch" if reasons.empty?

  case repo
  when "rubocop-lts"
    # rubocop-lts major is branch-lane identity; breaking internals still map to minor.
    "minor"
  when /\Arubocop-ruby/
    "major"
  else
    # conservative default for direct-consumer gems with compatibility drops.
    "major"
  end
end


def latest_tag(repo_dir)
  tags = run_cmd("git", "--no-pager", "tag", "--list", "v*", chdir: repo_dir)
         .lines.map(&:strip).reject(&:empty?)
  return nil if tags.empty?

  tags.max_by { |tag| Gem::Version.new(tag.delete_prefix("v")) }
end


def sorted_tags(repo_dir)
  run_cmd("git", "--no-pager", "tag", "--list", "v*", chdir: repo_dir)
    .lines.map(&:strip).reject(&:empty?)
    .sort_by { |tag| Gem::Version.new(tag.delete_prefix("v")) }
end


def build_repo_report(repo)
  repo_dir = WORKSPACE_DIR.join(repo)
  tags = sorted_tags(repo_dir)
  tag = tags.last
  previous_tag = tags[-2]

  version_file = Dir[repo_dir.join("lib", "**", "version.rb")].first
  raise "No version.rb found for #{repo}" unless version_file

  head_version = parse_version_rb(File.read(version_file))
  raise "Could not parse head version for #{repo}" unless head_version

  tag_version = tag&.delete_prefix("v")
  previous_tag_version = previous_tag&.delete_prefix("v")
  commits_since_tag = if tag
                        run_cmd("git", "rev-list", "--count", "#{tag}..HEAD", chdir: repo_dir).strip.to_i
                      else
                        0
                      end

  head_gemspec = File.read(Dir[repo_dir.join("*.gemspec")].first)
  tag_gemspec = if tag
                  run_cmd("git", "show", "#{tag}:#{repo}.gemspec", chdir: repo_dir)
                else
                  ""
                end
  previous_tag_gemspec = if previous_tag
                           run_cmd("git", "show", "#{previous_tag}:#{repo}.gemspec", chdir: repo_dir)
                         else
                           ""
                         end

  reasons = []

  old_floor = parse_required_ruby_min(tag_gemspec)
  new_floor = parse_required_ruby_min(head_gemspec)
  if old_floor && new_floor && new_floor > old_floor
    reasons << "required_ruby_version #{old_floor} -> #{new_floor}"
  end

  old_std, = parse_dependency_bounds(tag_gemspec, "standard-rubocop-lts")
  new_std, = parse_dependency_bounds(head_gemspec, "standard-rubocop-lts")
  if old_std && new_std && new_std.segments.first > old_std.segments.first
    reasons << "standard-rubocop-lts major #{old_std.segments.first} -> #{new_std.segments.first}"
  end

  required_bump = required_bump_for(repo, reasons)
  actual_bump = tag_version ? semver_bump(tag_version, head_version) : "none"

  latest_release_reasons = []
  if previous_tag
    prev_floor = parse_required_ruby_min(previous_tag_gemspec)
    rel_floor = parse_required_ruby_min(tag_gemspec)
    if prev_floor && rel_floor && rel_floor > prev_floor
      latest_release_reasons << "required_ruby_version #{prev_floor} -> #{rel_floor}"
    end

    prev_std, = parse_dependency_bounds(previous_tag_gemspec, "standard-rubocop-lts")
    rel_std, = parse_dependency_bounds(tag_gemspec, "standard-rubocop-lts")
    if prev_std && rel_std && rel_std.segments.first > prev_std.segments.first
      latest_release_reasons << "standard-rubocop-lts major #{prev_std.segments.first} -> #{rel_std.segments.first}"
    end
  end

  latest_release_required_bump = required_bump_for(repo, latest_release_reasons)
  latest_release_actual_bump = if previous_tag_version && tag_version
                                 semver_bump(previous_tag_version, tag_version)
                               else
                                 "none"
                               end

  current_major = head_version.split(".").first.to_i
  unreleased_major_shortfall = required_bump == "major" && BUMP_RANK.fetch(actual_bump) < BUMP_RANK.fetch("major")
  major_correction_needed = unreleased_major_shortfall
  next_major = major_correction_needed ? current_major + 1 : current_major

  RepoReport.new(
    repo: repo,
    head_version: head_version,
    tag_version: tag_version,
    previous_tag: previous_tag,
    previous_tag_version: previous_tag_version,
    latest_tag: tag,
    commits_since_tag: commits_since_tag,
    required_bump: required_bump,
    actual_bump: actual_bump,
    latest_release_required_bump: latest_release_required_bump,
    latest_release_actual_bump: latest_release_actual_bump,
    latest_release_reasons: latest_release_reasons,
    major_correction_needed: major_correction_needed,
    reasons: reasons,
    next_major: next_major
  )
end


def branch_bump_required(reasons)
  reasons.empty? ? "patch" : "minor"
end

require_tags = parse_args(ARGV)

reports = REPOS.to_h { |repo| [repo, build_repo_report(repo)] }

puts "release_bump_plan workspace=#{WORKSPACE_DIR}"
puts "require_tags=#{require_tags}"
puts
puts "Latest release policy audit (previous tag -> latest tag)"
puts "repo|previous|latest|required|actual|status|reason"
release_failures = 0

reports.each_value do |report|
  status = "ok"
  reason = report.latest_release_reasons.join("; ")

  if report.previous_tag && BUMP_RANK.fetch(report.latest_release_actual_bump) < BUMP_RANK.fetch(report.latest_release_required_bump)
    status = require_tags ? "FAIL" : "WARN"
    release_failures += 1 if require_tags
  end

  puts [
    report.repo,
    report.previous_tag || "-",
    report.latest_tag || "-",
    report.latest_release_required_bump,
    report.latest_release_actual_bump,
    status,
    reason.empty? ? "-" : reason
  ].join("|")
end

puts
puts "Repo bump audit"
puts "repo|tag|head|commits|required|actual|status|reason"
repo_failures = 0

reports.each_value do |report|
  status = "ok"
  reason = report.reasons.join("; ")

  if report.commits_since_tag > 0 && BUMP_RANK.fetch(report.actual_bump) < BUMP_RANK.fetch(report.required_bump)
    status = "FAIL"
    repo_failures += 1
  end

  puts [
    report.repo,
    report.latest_tag || "-",
    report.head_version,
    report.commits_since_tag,
    report.required_bump,
    report.actual_bump,
    status,
    reason.empty? ? "-" : reason
  ].join("|")
end

puts
puts "rubocop-lts branch dependency/bump audit"
puts "branch|wrapper|required|actual|status|details"
branch_failures = 0

lts_dir = WORKSPACE_DIR.join("rubocop-lts")

RUBOCOP_LTS_BRANCHES.each do |branch, wrapper_repo|
  _stdout, _stderr, exists = safe_cmd("git", "rev-parse", "--verify", branch, chdir: lts_dir)
  unless exists
    puts [branch, wrapper_repo, "-", "-", "FAIL", "missing local branch"].join("|")
    branch_failures += 1
    next
  end

  head_version = parse_version_rb(run_cmd("git", "show", "#{branch}:lib/rubocop/lts/version.rb", chdir: lts_dir))
  tag = "v#{head_version}"
  branch_gemspec = run_cmd("git", "show", "#{branch}:rubocop-lts.gemspec", chdir: lts_dir)

  _tag_stdout, _tag_stderr, tag_exists = safe_cmd("git", "rev-parse", "--verify", tag, chdir: lts_dir)
  commits_since = 0
  tag_gemspec = ""
  unless tag_exists
    if require_tags
      puts [branch, wrapper_repo, "-", "-", "FAIL", "missing tag #{tag}"].join("|")
      branch_failures += 1
      next
    end
  else
    commits_since = run_cmd("git", "rev-list", "--count", "#{tag}..#{branch}", chdir: lts_dir).strip.to_i
    tag_gemspec = run_cmd("git", "show", "#{tag}:rubocop-lts.gemspec", chdir: lts_dir)
  end

  old_floor = parse_required_ruby_min(tag_gemspec)
  new_floor = parse_required_ruby_min(branch_gemspec)

  old_std, = parse_dependency_bounds(tag_gemspec, "standard-rubocop-lts")
  new_std, = parse_dependency_bounds(branch_gemspec, "standard-rubocop-lts")

  old_wrap, = parse_dependency_bounds(tag_gemspec, wrapper_repo)
  new_wrap, new_wrap_upper = parse_dependency_bounds(branch_gemspec, wrapper_repo)

  reasons = []
  if old_floor && new_floor && new_floor > old_floor
    reasons << "required_ruby_version #{old_floor} -> #{new_floor}"
  end
  if old_std && new_std && new_std.segments.first > old_std.segments.first
    reasons << "standard-rubocop-lts major #{old_std.segments.first} -> #{new_std.segments.first}"
  end
  if old_wrap && new_wrap && new_wrap.segments.first > old_wrap.segments.first
    reasons << "#{wrapper_repo} major #{old_wrap.segments.first} -> #{new_wrap.segments.first}"
  end

  wrapper_plan_major = reports.fetch(wrapper_repo).next_major
  dep_lower_major = new_wrap&.segments&.first
  dep_upper_major = new_wrap_upper&.segments&.first

  dep_major_mismatch = dep_lower_major != wrapper_plan_major || dep_upper_major != (wrapper_plan_major + 1)
  reasons << "#{wrapper_repo} dep should target >= #{wrapper_plan_major}.0.0, < #{wrapper_plan_major + 1}" if dep_major_mismatch

  required_bump = branch_bump_required(reasons)
  actual_bump = semver_bump(head_version, head_version)
  status = "ok"

  unless tag_exists
    status = "WARN"
    reasons << "missing tag #{tag} (advisory without --require-tags)"
  end

  if commits_since > 0
    if required_bump == "minor"
      status = require_tags ? "FAIL" : "WARN"
      branch_failures += 1 if require_tags
      actual_bump = "none"
    elsif dep_major_mismatch
      status = "FAIL"
      branch_failures += 1
    end
  elsif dep_major_mismatch
    status = "FAIL"
    branch_failures += 1
  end

  puts [
    branch,
    wrapper_repo,
    required_bump,
    actual_bump,
    status,
    reasons.empty? ? "-" : reasons.join("; ")
  ].join("|")
end

failures = repo_failures + branch_failures
failures += release_failures
puts
puts "Summary: release_failures=#{release_failures} repo_failures=#{repo_failures} branch_failures=#{branch_failures} total_failures=#{failures}"
exit(failures.zero? ? 0 : 1)
