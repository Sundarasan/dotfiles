#!/usr/bin/env ruby

# file location: <anywhere; but advisable in the PATH>

# This script is used to install the dotfiles from this repo/folder structure to the user's home folder
# It can be invoked from any location as long as its in the PATH (and you don't need to specify the fully qualified name while invoking it).
# It can handle nested files.
# If there is already a real file (not a symbolic link), then the script will move that file into this repo, and then create the corresponding symlink. This helps preserve the current settings from the user without forcefully overriding from my repo.
# Special handling (rename + copy instead of symlink) for '.gitattributes' and '.gitignore'
# To run it, just invoke by `install-dotfiles.rb` if this folder is already setup in the PATH

# It assumes the following:
#   1. Ruby language is present in the system prior to this script being run.

require "#{__dir__}/utilities/file.rb"
require "#{__dir__}/utilities/string.rb"
require 'fileutils'
require 'find'
require 'pathname'

# Helper to interpolate environment variables in paths like --VAR--
def interpolate_path(path_template, source_file_for_context)
  # process folder names having '--' in their name (strings within two pairs of '--' will refer to env variables)
  # if tne env var is not defined, then skip processing that file
  env_vars_ok = true
  interpolated_path = path_template.gsub(/--(.*?)--/) do |match|
    var_name = $1
    if ENV[var_name]
      ENV[var_name]
    else
      puts "**WARN** Skipping processing involving '#{source_file_for_context}' because env var '#{var_name}' was not defined".yellow
      env_vars_ok = false
      match # Return the original match if skipping to avoid partial substitution issues
    end
  end
  env_vars_ok ? interpolated_path : nil
end

# Processes a single dotfile: moves existing real files, creates symlink/copy
def process_dotfile(source_file, target_file)
  puts "Processing #{source_file.yellow} --> #{target_file.yellow}"

  # Ensure target directory exists
  target_dir = File.dirname(target_file)
  # Use mkdir_p directly - it's idempotent and handles existence checks internally.
  FileUtils.mkdir_p(target_dir, verbose: false)

  begin
    # Check target status before deciding action
    if File.symlink?(target_file)
      puts "  Target #{target_file.cyan} exists as a symlink, will overwrite.".blue
      # Proceed to ln_sf or cp which will overwrite
    elsif File.exist?(target_file) # It exists and is not a symlink (real file/dir)
      puts "  Moving existing file #{target_file.cyan} to #{source_file.cyan} (backup)".blue
      FileUtils.mv(target_file, source_file, force: true, verbose: false)
    else
      # Target does not exist, no backup needed
      puts "  Target #{target_file.cyan} does not exist, creating new link/copy.".blue
    end

    # Create symlink or copy file
    if source_file.match?(/custom\.git/) # Special handling for git files
      puts "  Copying #{source_file.cyan} to #{target_file.cyan}".blue
      FileUtils.cp(source_file, target_file, verbose: false)
    else
      puts "  Creating symlink from #{source_file.cyan} to #{target_file.cyan}".blue
      FileUtils.ln_sf(source_file, target_file, verbose: false)
    end
  rescue StandardError => e
    puts "**ERROR** Failed during processing of #{source_file} -> #{target_file}: #{e.message}".red
  end
end

puts 'Starting to install dotfiles'.green
HOME = ENV['HOME']
dotfiles_dir = File.expand_path(File.join(__dir__, '..', 'files'))
dotfiles_dir_length = dotfiles_dir.length + 1 # Length of the base path + '/'

Find.find(dotfiles_dir) do |source_path|
  next if File.directory?(source_path) || source_path.end_with?('.DS_Store') || source_path.match?(/\.zwc/)

  # git doesn't handle symlinks well for its core config, handle separately
  relative_file_name = source_path[dotfiles_dir_length..-1].gsub('custom.git', '.git')

  interpolated_relative_name = interpolate_path(relative_file_name, source_path)
  next unless interpolated_relative_name # Skip if env var interpolation failed

  # since some env var might already contain the full path from the root...
  target_file_name = interpolated_relative_name.start_with?(HOME) ? interpolated_relative_name : File.join(HOME, interpolated_relative_name)
  process_dotfile(source_path, target_file_name)
end

ssh_folder = Pathname.new(HOME) + '.ssh'
default_ssh_config = ssh_folder + 'config'
global_config_link = ssh_folder + 'global_config' # The symlink potentially created above

# Check if the global_config symlink exists and points to a valid file
if global_config_link.symlink? && global_config_link.exist?
  FileUtils.touch(default_ssh_config) unless default_ssh_config.exist?

  include_line = 'Include ${HOME}/.ssh/global_config'
  include_line_present = false
  begin
    # Read lines to check precisely, handling potential comments or variations
    default_ssh_config.readlines.each do |line|
      if line.strip == include_line.strip # Check content ignoring leading/trailing whitespace
        include_line_present = true
        break
      end
    end

    unless include_line_present
      puts "Adding '#{include_line}' to #{default_ssh_config}".blue
      # Append with surrounding newlines for safety
      File.write(default_ssh_config, "\n#{include_line}\n", mode: 'a')
    else
      puts "'#{include_line}' already present in #{default_ssh_config}".green
    end
  rescue StandardError => e
    puts "**ERROR** Failed processing SSH config #{default_ssh_config}: #{e.message}".red
  end
else
  puts "**WARN** Skipping SSH config update because '#{global_config_link}' does not exist or is not a symlink.".yellow
end

puts "Since the '.gitignore' and '.gitattributes' files are COPIED over, any new changes being pulled in (from a newer version of the upstream repo) need to be manually reconciled between this repo and your home and profiles folders".red
