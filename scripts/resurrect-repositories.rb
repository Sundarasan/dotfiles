#!/usr/bin/env ruby

# file location: <anywhere; but advisable in the PATH>

require 'tempfile'
require "#{__dir__}/utilities/string.rb"

def usage(exit_code = -1)
  puts 'This script resurrects or flags for backup all known repositories in the current machine'
  puts "#{'Usage:'.pink} #{__FILE__} [-g <folder-to-generate-config-for>] [-r <config-filename>] [-c <config-filename>]".yellow
  puts "  #{'-g'.green} generates the configuration contents onto the stdout for codebases (usually on current laptop). #{"Please note that this option will not handle 'post_clone' commands in the generated yaml structure".red}"
  puts "  #{'-r'.green} resurrects 'known' codebases (usually on fresh laptop)"
  puts "  #{'-c'.green} verifies 'known' codebases"
  puts 'Environment variables:'.yellow
  puts "  #{'FILTER'.light_blue} can be used to apply the operation to a subset of codebases (will match on folder or repo name)"
  puts "  #{'REF_FOLDER'.light_blue} can be used to apply a filter when verifying against a specific yaml file that might not contain all the repos in your system"
  exit(exit_code)
end

usage(0) if ARGV[0] == '--help'
usage if ARGV.length != 2 || !['-g', '-r', '-c'].include?(ARGV[0])

require 'fileutils'
require 'set'
require 'yaml'

# frozen string constants (defined for performance)
ORIGIN_NAME = 'origin'.freeze
FOLDER_KEY_NAME = 'folder'.freeze
OTHER_REMOTES_KEY_NAME = 'other_remotes'.freeze
POST_CLONE_KEY_NAME = 'post_clone'.freeze

# utility functions
def nil_or_empty?(val)
  val.nil? || val.empty?
end

def justify(num)
  num.to_s.rjust(2, ' ')
end

def find_and_replace_env_var(folder)
  env_var_name = folder[/.*\$\{(.*)}/, 1]
  nil_or_empty?(env_var_name) ? folder : folder.gsub("${#{env_var_name}}", ENV[env_var_name])
end

def git_repo?(folder)
  Dir.exist?("#{folder}/.git")
end

def find_git_remote_url(git_cmd, remote_name)
  `#{git_cmd} config remote.#{remote_name}.url`.strip
end

def find_git_repos_from_disk(path)
  stderr = Tempfile.new
  begin
    paths = `find '#{path}' -name .git -type d -not -regex '.*/\\..*/\\.git' -exec dirname {} \\; 2>#{stderr.path}`
    unless File.zero?(stderr.path)
      puts 'WARNING: Following errors occurred when traversing directories for git repositories:'.yellow
      puts `cat #{stderr.path}`.yellow
    end
    return paths.split("\n").sort
  ensure
    stderr.close
    stderr.unlink
  end
end

def read_git_repos_from_file(filename)
  yml_file = File.expand_path(filename)
  puts "Using config file: #{yml_file.green}"
  repositories = YAML.load_file(yml_file).select { |repo| repo['active'] }
  repositories.each do |repo|
    repo[FOLDER_KEY_NAME] = find_and_replace_env_var(repo[FOLDER_KEY_NAME].strip)
  end
  repositories
end

def apply_filter(repos, filter)
  return repos if nil_or_empty?(filter)

  repos.select { |repo| find_and_replace_env_var(repo.is_a?(String) ? repo : repo[FOLDER_KEY_NAME]).strip =~ /#{filter}/i }
end

# main functions
def generate_each(git_dir)
  git_cmd = "git -C #{git_dir}"
  hash = { folder: git_dir, active: true }
  other_remotes = {}

  # Get all remotes and their fetch URLs in one call
  remote_output = `#{git_cmd} remote -v`
  remote_output.lines.each do |line|
    name, url, type = line.split
    next unless type == '(fetch)' # Only consider fetch URLs to avoid duplicates

    if name == ORIGIN_NAME
      hash[:remote] = url # Set the primary remote URL
    else
      other_remotes[name] = url
    end
  end

  # Fallback if origin wasn't found via `remote -v` (unlikely but safe)
  hash[:remote] ||= find_git_remote_url(git_cmd, ORIGIN_NAME)

  hash[OTHER_REMOTES_KEY_NAME] = other_remotes unless other_remotes.empty?
  hash
end

def resurrect_each(repo, idx, total)
  folder = repo[FOLDER_KEY_NAME]
  FileUtils.mkdir_p(folder)

  puts "***** Resurrecting [#{justify(idx + 1)} of #{justify(total)}]: #{folder} *****".green
  git_cmd = "git -C #{folder}"

  existing_remotes = {} # Store existing remotes {name => url}
  if git_repo?(folder)
    puts 'Already an existing git repo. Checking remotes...'.yellow
    remote_output = `#{git_cmd} remote -v`
    remote_output.lines.each do |line|
      name, url, type = line.split
      existing_remotes[name] = url if type == '(fetch)'
    end
    puts "Existing remotes: #{existing_remotes.keys.join(', ')}" unless existing_remotes.empty?
  else
    clone_success = system("source \"#{ENV['HOME']}/.shellrc\" && clone_repo_into \"#{repo['remote']}\" \"#{folder}\"")
    abort("Failed to clone '#{repo['remote']}' into '#{folder}'; aborting".red) unless clone_success
    # After successful clone, origin should exist
    existing_remotes[ORIGIN_NAME] = repo['remote'] # Assume origin matches the cloned URL
  end

  # Add missing 'other_remotes'
  Array(repo[OTHER_REMOTES_KEY_NAME]).each do |name, remote|
    if !existing_remotes.key?(name) # Check against the fetched list
      puts "Adding remote '#{name}' -> '#{remote}'".blue
      add_remote_success = system("#{git_cmd} remote add #{name} #{remote}")
      puts "WARNING: Failed to add remote '#{name}' for repo '#{folder}'".yellow unless add_remote_success
    elsif existing_remotes[name] != remote
      # Remote exists but URL is different
      puts "Updating remote '#{name}' URL from '#{existing_remotes[name]}' to '#{remote}'".blue
      update_remote_success = system("#{git_cmd} remote set-url #{name} #{remote}")
      puts "WARNING: Failed to update URL for remote '#{name}' in repo '#{folder}'".yellow unless update_remote_success
    end
  end if repo[OTHER_REMOTES_KEY_NAME]

  puts "Fetching all remotes and tags...".blue
  fetch_success = system("#{git_cmd} fetch -q --all --tags")
  puts "WARNING: Failed to fetch for repo '#{folder}'".yellow unless fetch_success

  if repo[POST_CLONE_KEY_NAME]
    puts "Running post-clone commands...".blue
    Dir.chdir(folder) { system(Array(repo[POST_CLONE_KEY_NAME]).join(';')) || puts("WARNING: Post-clone command failed for repo '#{folder}'".yellow) }
  end
end

def verify_all(repositories, filter)
  ref_folder = File.expand_path(ENV['REF_FOLDER']) if ENV['REF_FOLDER']
  yml_folders = repositories.map { |repo| repo[FOLDER_KEY_NAME] }.compact.sort.uniq
  yml_folders = apply_filter(yml_folders, ref_folder) if ref_folder

  local_folders = find_git_repos_from_disk(ref_folder || ENV['HOME'])
  local_folders = apply_filter(local_folders, filter).compact.sort.uniq

  # Convert to Sets for potentially faster difference/union operations on large lists
  yml_set = Set.new(yml_folders)
  local_set = Set.new(local_folders)
  diff_repos_set = (local_set - yml_set) | (yml_set - local_set)
  diff_repos = diff_repos_set.to_a.sort # Convert back to sorted array for consistent output

  if diff_repos.any?
    puts "Please correlate the following #{diff_repos.length} differences projects manually:\n#{diff_repos.join("\n")}".red
    exit(-1)
  else
    puts 'Everything is kosher!'.green
  end
end

# main program
filter = (ENV['FILTER'] || '').strip
puts "Using filter: #{filter.green}" unless filter.empty?

case ARGV[0]
when '-g'
  puts "Running operation: #{'generation'.green}"
  discovery_dir = File.expand_path(ARGV[1])
  puts "Discovering repos under: #{discovery_dir.green}"
  repositories = find_git_repos_from_disk(discovery_dir)
  repositories = apply_filter(repositories, filter)
  puts repositories.map { |dir| generate_each(dir) }.to_yaml
when '-r'
  puts "Running operation: #{'resurrection'.green}"
  repositories = read_git_repos_from_file(ARGV[1])
  repositories = apply_filter(repositories, filter)
  repositories.each_with_index do |repo, idx|
    resurrect_each(repo, idx, repositories.length)
  end
when '-c'
  puts "Running operation: #{'verification'.green}"
  repositories = read_git_repos_from_file(ARGV[1])
  repositories = apply_filter(repositories, filter)
  verify_all(repositories, filter)
else
  usage
end
