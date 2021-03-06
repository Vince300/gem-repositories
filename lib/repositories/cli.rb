require 'repositories/base'
require 'repositories/host_config'
require 'repositories/actors/ssh_updater'

require 'fileutils'
require 'yaml'
require 'optparse'
require 'ostruct'

module Repositories
  module CLI
    def self.parse(argv)
      options = OpenStruct.new
      options.hosts = 'hosts.yml'
      options.force = false
      options.dry_run = false
      options.list = nil
      options.only = []
      options.scrub = false
      options.scrub_only = false
      options.verbose = false

      opt_parser = OptionParser.new do |opts|
        opts.banner = "Usage: repupdate [options]"

        opts.on("-h", "--hosts [PATH]", "Host config file") do |hosts|
          options.hosts = hosts
        end

        opts.on("-n", "--dry-run", "Do not perform actions on repositories") do
          options.dry_run = true
        end

        opts.on("-f", "--force", "Force push to backup repositories") do
          options.force = true
        end

        opts.on("-l", "--list [NAME]", "List discovered repositories") do |name|
          options.list = name
        end

        opts.on("-o", "--only [NAME]", "Only consider specific repositories") do |name|
          options.only << Repository.to_rep_name(name)
        end

        opts.on("-s", "--scrub", "Remove repositories not present in source") do
          options.scrub = true
        end

        opts.on("-S", "--scrub-only", "Only remove repositories not present in source") do
          options.scrub_only = true
        end

        opts.on("-v", "--verbose", "Enable verbose mode") do
          options.verbose = true
        end
      end
      opt_parser.parse!(argv)
      options
    end

    def self.run(argv)
      # Parse options
      options = parse(argv)

      # Load config for Git hosts
      host_config = HostConfig.load(options.hosts)

      if options.scrub_only
        run_scrub(options, host_config)
      elsif options.list.nil?
        res = run_backup(options, host_config)

        if options.scrub
          if res == 0
            res = run_scrub(options, host_config)
          else
            STDERR.puts "Not continuing with scrub since backup failed"
          end
        end

        res
      else
        run_list(options, host_config)
      end
    end

    def self.run_scrub(options, host_config)
      # Build a hash of all repositories
      host_repositories = hr(host_config, options.only)

      # Find repositories on the backup hosts
      status = {}

      host_config.hosts_by_use[:backup].each do |backup_host|
        host_repositories[backup_host.name].each do |backup_rep|
          if m = /^\[backup\] (.*)$/.match(backup_rep.description)
            STDERR.puts "#{backup_rep.web_url} is a backup of #{m[1]} (as #{backup_rep.normalized_name})"

            status[backup_rep.normalized_name] = {
              found: false,
              backup_rep: backup_rep
            }
          end
        end
      end

      host_config.hosts_by_use[:source].each do |source_host|
        host_repositories[source_host.name].each do |source_rep|
          if status.include? source_rep.normalized_name
            status[source_rep.normalized_name][:found] = true
          else
            STDERR.puts "#{source_rep.web_url} has not been backed up yet"
          end
        end
      end

      host_config.keep_repos.each do |repo_name|
        if status.include? repo_name
          status[repo_name][:found] = true
        end
      end

      code = 0

      status.each do |name, rep_status|
        unless rep_status[:found]
          begin
            unless options.dry_run
              rep = rep_status[:backup_rep]
              rep.host.delete_repository(rep)
              STDERR.puts "#{rep_status[:backup_rep].web_url} deleted"
            else
              STDERR.puts "#{rep_status[:backup_rep].web_url} is to be deleted"
            end
          rescue => e
            STDERR.puts "#{rep_status[:backup_rep].web_url} error: #{e.inspect}"
            code = 2
          end
        end
      end

      code
    end

    def self.run_list(options, host_config)
      if !(host = host_config.hosts[options.list]).nil?
        host.repositories.each do |repository|
          if options.verbose
            p repository
          else
            puts repository.name
          end
        end

        0
      else
        STDERR.puts "#{options.list}: host not found"

        1
      end
    end

    def self.run_backup(options, host_config)
      # Build a hash of all repositories
      host_repositories = hr(host_config, options.only)

      # Check all source repositories
      named_repositories = Hash.new { |hash, key| hash[key] = [] }

      host_config.hosts_by_use[:source].each do |host|
        host_repositories[host.name].each do |rep|
          named_repositories[rep.normalized_name] << rep
        end
      end

      # From named_repositories, determine source repositories to clone to
      # backup hosts depending on most recent commits
      source_repositories = {}

      named_repositories.each do |nn, reps|
        ref_rep = reps[0]
        unmatch_count = 0

        if reps.length > 1
          reps.drop(1).each do |other_rep|
            diff_state = ref_rep.find_differences(other_rep)
            print_diff_state(ref_rep, other_rep, diff_state) do
              unmatch_count += 1
            end
          end
        end

        if unmatch_count > 0
          ref_rep = reps.max_by { |rep| rep.host.priority }
          STDERR.puts "On #{ref_rep.name}: differences were found between "\
                      "source repositories. Using #{ref_rep.host.name} as a "\
                      "source."
        else
          STDERR.puts "All source repositories for #{ref_rep.name} are at the "\
                      "same revision."
        end

        source_repositories[nn] = ref_rep
      end

      # Check that all named repositories have an equivalent in all backups
      exit_code = 0
      updater = Repositories::Actors::SSHUpdater.new(options)

      source_repositories.each do |nn, rep|
        host_config.hosts_by_use[:backup].each do |backup_host|
          backup_rep = host_repositories[backup_host.name].find { |br| br.normalized_name == nn }

          should_update = false
          description = "[backup] #{rep.web_url}"

          if backup_rep
            # Found a matching backup repository on backup host
            diff_state = rep.find_differences(backup_rep)

            print_diff_state(rep, backup_rep, diff_state) do
              should_update = true
            end
          else
            # Found no matching backup repository
            STDERR.puts "#{rep.name} (#{nn}) is missing from #{backup_host.name}"
            should_update = true

            # Create repository
            unless options.dry_run
              STDERR.print "Creating repository... "
              backup_rep = backup_host.create_repository(rep.name, description)
              STDERR.puts "completed at #{rep.ssh_url}"
            else
              STDERR.puts "Creating repository on #{backup_host.name}"
            end
          end

          if !options.dry_run && backup_rep.description != description
            STDERR.puts "Updating #{backup_rep.web_url} description"
            unless options.dry_run
              backup_host.update_description(backup_rep, description)
            end
          end

          next unless should_update

          STDERR.puts "Updating #{rep.name} on #{backup_host.name}"
          unless options.dry_run
            unless updater.update(rep, backup_rep)
              exit_code = 1
            end
          end
        end
      end

      exit_code # success
    end

    def self.fetch_host_repositories(type, host)
      STDERR.puts "Fetching #{type} repositories..."
      begin
        return host.repositories
      rescue => e
        STDERR.puts "#{type}: failed to fetch repositories: #{e}"
        if host.use_as == :backup
          raise "Failed to fetch backup host repositories"
        else
          return []
        end
      end
    end

    def self.hr(host_config, only_repos)
      reps = {}

      only_repos = Set.new(only_repos)
      host_config.hosts.each do |type, host|
        reps[type] = begin
                       fetch_host_repositories(type, host).select do |repo|
                         only_repos.empty? || only_repos.include?(repo.name)
                       end.to_a
                     rescue => e
                       STDERR.puts "Cannot continue, aborting: #{e}"
                       exit(2)
                     end
      end

      reps
    end

    def self.print_diff_state(ref, other, state)
      return if state.empty?

      STDERR.puts "On #{ref.name}: differing branch state between "\
                  "#{ref.host.name} and #{other.host.name}"
      STDERR.puts YAML.dump(differences: state)
      yield if block_given?
    end
  end
end
