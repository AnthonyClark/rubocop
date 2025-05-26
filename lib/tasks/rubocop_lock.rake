# frozen_string_literal: true

# -----------------------------------------------------------------------------
# RuboCop Configuration Lockfile Management
# -----------------------------------------------------------------------------
#
# Purpose of `rubocop.lock.yml`:
# This file records the fully resolved, effective RuboCop configuration for the
# project. It is deterministically generated based on your `.rubocop.yml`,
# any files inherited via `inherit_from`, and any configurations inherited
# from gems via `inherit_gem`.
# Its main benefits are:
#   - Consistency: Ensures all developers and CI environments use the exact
#     same RuboCop rule settings.
#   - Visibility: Makes changes to the effective rule set (e.g., due to gem
#     updates) explicit and reviewable through version control history.
#   - Portability: Local file paths within the project (e.g., in `Exclude`
#     patterns) are normalized to use a `<PROJECT_ROOT>` placeholder,
#     ensuring the lockfile remains consistent across different machines.
#
# Generating and Updating `rubocop.lock.yml`:
# To generate or update the lockfile, run the following Rake task:
#
#   bundle exec rake rubocop:generate_lockfile
#
# It's recommended to run this task after:
#   - Modifying your project's `.rubocop.yml` file.
#   - Updating gems that might contribute to the RuboCop configuration
#     (those included via `inherit_gem`).
#
# Version Control:
# `rubocop.lock.yml` should be committed to your project's version control
# system. This allows tracking changes to the effective RuboCop configuration
# over time.
#
# Implementation Note: These tasks now interact directly with RuboCop's Ruby API
# to obtain configuration information, ensuring greater robustness and
# efficiency compared to shelling out to the `rubocop` executable.
#
# Optional: Enforcing Lockfile Freshness:
# For projects desiring a stricter workflow, this Rake setup will also provide
# a task to verify that `rubocop.lock.yml` is up-to-date before running
# your main RuboCop analysis.
#
#   How it will work (this task will be created separately):
#   A task named `rubocop:check_lockfile` can be invoked. This task will:
#     1. Silently generate the current effective RuboCop configuration.
#     2. Compare it against the content of the existing `rubocop.lock.yml`.
#     3. If they differ, it will print an error message and exit with a
#        non-zero status, suitable for failing a CI build.
#
#   To use this optional check:
#   In your CI script or local linting script, call this task *before* your
#   main RuboCop analysis command:
#
#     bundle exec rake rubocop:check_lockfile && \
#     bundle exec rubocop
#
#   If `rubocop:check_lockfile` passes, your linting will proceed. If it fails,
#   it will indicate that `rubocop.lock.yml` needs to be regenerated and
#   committed. Projects not needing this strict enforcement can simply not use
#   the `rubocop:check_lockfile` task.
#
# -----------------------------------------------------------------------------

require 'yaml' # Still needed for YAML.dump in generate_lockfile and YAML.safe_load in check_lockfile
require 'fileutils' # For potential future use
require 'rubocop' # Required for using the RuboCop API

# Helper method to recursively normalize paths within a configuration structure.
# Replaces occurrences of the project_root_path with "<PROJECT_ROOT>".
# Made private by convention with a leading underscore.
def _normalize_paths_in_config(item, project_root_path)
  case item
  when Hash
    item.transform_values { |value| _normalize_paths_in_config(value, project_root_path) }
  when Array
    item.map { |element| _normalize_paths_in_config(element, project_root_path) }
  when String
    if item == project_root_path
      '<PROJECT_ROOT>'
    elsif item.start_with?(project_root_path + '/')
      item.sub(project_root_path, '<PROJECT_ROOT>')
    else
      item
    end
  else
    item # Return other types as is
  end
end

# Helper method to recursively sort a hash.
# Made private by convention with a leading underscore.
def _deep_sort_hash(object)
  if object.is_a?(Hash)
    object.keys.sort.each_with_object({}) do |key, new_hash|
      new_hash[key] = _deep_sort_hash(object[key])
    end
  elsif object.is_a?(Array)
    object.map { |item| _deep_sort_hash(item) }
  else
    object
  end
end

# Helper method to get the current, normalized, and sorted RuboCop configuration
# using the RuboCop API.
# Returns [normalized_and_sorted_config, error_message]. error_message is nil on success.
def _get_current_sorted_rubocop_config
  current_config_data = nil
  error_message = nil

  begin
    config_store = RuboCop::ConfigStore.new
    project_config = config_store.for_pwd 

    raw_config_hash = {}

    all_cops_settings = project_config.for_all_cops
    raw_config_hash['AllCops'] = all_cops_settings.dup if all_cops_settings && !all_cops_settings.empty?

    RuboCop::Cop::Registry.all.each do |cop_klass|
      cop_name_str = cop_klass.cop_name 
      cop_specific_config = project_config.for_cop(cop_klass)
      raw_config_hash[cop_name_str] = cop_specific_config.dup if cop_specific_config && !cop_specific_config.empty?
    end

    current_config_data = raw_config_hash
    error_message = nil # Success
  rescue StandardError => e
    current_config_data = nil
    error_message = "Error fetching RuboCop config via API: #{e.class.name} - #{e.message}\nBacktrace:\n#{e.backtrace.join("\n")}"
  end

  if error_message # If API fetching failed, return immediately
    return [nil, error_message]
  end

  unless current_config_data.is_a?(Hash) # Should be a hash if API call was successful
    return [nil, "Fetched configuration via API is not a Hash. Actual type: #{current_config_data.class}"]
  end

  current_project_root = File.expand_path(Dir.pwd)
  normalized_config = _normalize_paths_in_config(current_config_data, current_project_root)
  
  normalized_and_sorted_config = _deep_sort_hash(normalized_config)
  [normalized_and_sorted_config, nil] # error_message is nil here because API call and processing were successful
end

namespace :rubocop do
  desc "Generates a rubocop.lock.yml file with the fully resolved cop configurations."
  task :generate_lockfile do
    puts "Generating RuboCop lockfile..."
    
    puts "Fetching current RuboCop configuration using API..."
    processed_config, error_msg = _get_current_sorted_rubocop_config

    unless processed_config
      warn "ERROR: #{error_msg}" 
      exit 1 
    end
    
    puts "Current configuration fetched, normalized, and sorted successfully."

    header = <<~YAML_HEADER
      # This file is auto-generated by the 'rubocop:generate_lockfile' Rake task.
      # Do not edit it manually. Your changes will be overwritten.
      #
      # This file tracks the fully resolved RuboCop configuration for your project,
      # ensuring consistent linting results across environments.
    YAML_HEADER

    lockfile_path = 'rubocop.lock.yml'
    begin
      puts "Generating YAML string from processed configuration..."
      yaml_output = YAML.dump(processed_config)

      puts "Writing configuration to '#{lockfile_path}'..."
      File.open(lockfile_path, 'w') do |file|
        file.puts header
        file.puts yaml_output
      end
      puts "'#{lockfile_path}' has been generated successfully."
    rescue StandardError => e
      warn "Error writing '#{lockfile_path}': #{e.message}"
      exit 1
    end
  end

  desc "Checks if rubocop.lock.yml is up-to-date with the current configuration."
  task :check_lockfile do
    puts "Checking RuboCop lockfile status..."

    unless ENV['RUBOCOP_VALIDATE_LOCKFILE']&.downcase == 'true'
      puts "RUBOCOP_VALIDATE_LOCKFILE not set to 'true', skipping check."
      exit 0
    end

    puts "RUBOCOP_VALIDATE_LOCKFILE is true. Proceeding with lockfile validation."
    
    lockfile_path = 'rubocop.lock.yml'

    unless File.exist?(lockfile_path)
      warn "ERROR: '#{lockfile_path}' is missing. Please generate it using `rake rubocop:generate_lockfile`."
      exit 1
    end

    puts "Fetching current RuboCop configuration using API for comparison..."
    current_processed_config, error_msg = _get_current_sorted_rubocop_config

    unless current_processed_config
      warn "ERROR fetching current configuration: #{error_msg}"
      exit 1 
    end
    puts "Current configuration fetched, normalized, and sorted successfully."

    puts "Reading existing '#{lockfile_path}'..."
    begin
      lockfile_content = File.read(lockfile_path)
      lockfile_config = YAML.safe_load(lockfile_content, aliases: true)
    rescue Psych::SyntaxError => e
      warn "ERROR: Failed to parse YAML from '#{lockfile_path}': #{e.message}"
      exit 1
    rescue StandardError => e
      warn "ERROR: Could not read or process '#{lockfile_path}': #{e.message}"
      exit 1
    end
    
    unless lockfile_config.is_a?(Hash)
        warn "ERROR: Content of '#{lockfile_path}' is not a valid RuboCop configuration hash."
        exit 1
    end

    puts "Comparing current configuration with '#{lockfile_path}'..."
    if current_processed_config == lockfile_config
      puts "'#{lockfile_path}' is up to date."
      exit 0
    else
      warn "ERROR: '#{lockfile_path}' is outdated or has been manually modified. Please regenerate it using `rake rubocop:generate_lockfile`."
      exit 1
    end
  end
end
