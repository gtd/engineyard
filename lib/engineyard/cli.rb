require 'engineyard'
require 'engineyard/error'
require 'engineyard/thor'

module EY
  class CLI < EY::Thor
    autoload :API,     'engineyard/cli/api'
    autoload :UI,      'engineyard/cli/ui'
    autoload :Recipes, 'engineyard/cli/recipes'
    autoload :Web,     'engineyard/cli/web'

    check_unknown_options!

    include Thor::Actions

    def self.start(*)
      Thor::Base.shell = EY::CLI::UI
      EY.ui = EY::CLI::UI.new
      super
    end

    desc "deploy [--environment ENVIRONMENT] [--ref GIT-REF]",
      "Deploy specified branch, tag, or sha to specified environment."
    long_desc <<-DESC
      This command must be run with the current directory containing the app to be
      deployed. If ey.yml specifies a default branch then the ref parameter can be
      omitted. Furthermore, if a default branch is specified but a different command
      is supplied the deploy will fail unless --ignore-default-branch is used.

      Migrations are run by default with 'rake db:migrate'. A different command can be
      specified via --migrate "ruby do_migrations.rb". Migrations can also be skipped
      entirely by using --no-migrate.
    DESC
    method_option :ignore_default_branch, :type => :boolean,
      :desc => "Force a deploy of the specified branch even if a default is set"
    method_option :ignore_bad_master, :type => :boolean,
      :desc => "Force a deploy even if the master is in a bad state"
    method_option :migrate, :type => :string, :aliases => %w(-m),
      :lazy_default => true,
      :desc => "Run migrations via [MIGRATE], defaults to 'rake db:migrate'; use --no-migrate to avoid running migrations"
    method_option :environment, :type => :string, :aliases => %w(-e),
      :desc => "Environment in which to deploy this application"
    method_option :ref, :type => :string, :aliases => %w(-r --branch --tag),
      :desc => "Git ref to deploy. May be a branch, a tag, or a SHA."
    method_option :app, :type => :string, :aliases => %w(-a),
      :desc => "Name of the application to deploy"
    method_option :verbose, :type => :boolean, :aliases => %w(-v),
      :desc => "Be verbose"
    method_option :extra_deploy_hook_options, :type => :hash, :default => {},
      :desc => "Additional options to be made available in deploy hooks (in the 'config' hash)"
    def deploy
      app         = fetch_app(options[:app])
      environment = fetch_environment(options[:environment], app)
      environment.ignore_bad_master = options[:ignore_bad_master]
      deploy_ref  = if options[:app]
                      environment.resolve_branch(options[:ref], options[:ignore_default_branch]) ||
                        raise(EY::Error, "When specifying the application, you must also specify the ref to deploy\nUsage: ey deploy --app <app name> --ref <branch|tag|ref>")
                    else
                      environment.resolve_branch(options[:ref], options[:ignore_default_branch]) ||
                        repo.current_branch ||
                        raise(DeployArgumentError)
                    end

      EY.ui.info "Connecting to the server..."

      loudly_check_engineyard_serverside(environment)

      EY.ui.info "Beginning deploy for '#{app.name}' in '#{environment.name}' on server..."

      deploy_options = {'extras' => options[:extra_deploy_hook_options]}
      deploy_options['migrate'] = options['migrate'] if options.has_key?('migrate')
      deploy_options['verbose'] = options['verbose'] if options.has_key?('verbose')

      if environment.deploy(app, deploy_ref, deploy_options)
        EY.ui.info "Deploy complete"
      else
        raise EY::Error, "Deploy failed"
      end

    rescue NoEnvironmentError => e
      # Give better feedback about why we couldn't find the environment.
      exists = api.environments.named(options[:environment])
      raise exists ? EnvironmentUnlinkedError.new(options[:environment]) : e
    end

    desc "environments [--all]", "List environments for this app; use --all to list all environments."
    long_desc <<-DESC
      By default, environments for this app are displayed. The --all option will
      display all environments, including those for this app.
    DESC

    method_option :all, :type => :boolean, :aliases => %(-a)
    method_option :simple, :type => :boolean, :aliases => %(-s)
    def environments
      if options[:all] && options[:simple]
        # just put each env
        api.environments.each do |env|
          puts env.name
        end
      else
        apps = get_apps(options[:all])
        if !options[:all] && apps.size > 1
          message = "This git repo matches multiple Applications in AppCloud:\n"
          apps.each { |app| message << "\t#{app.name}\n" }
          message << "The following environments contain those applications:\n\n"
          EY.ui.warn(message)
        end
        EY.ui.warn(NoAppError.new(repo).message) unless apps.any? || options[:all]
        EY.ui.print_envs(apps, EY.config.default_environment, options[:simple])
      end
    end
    map "envs" => :environments

    desc "rebuild [--environment ENVIRONMENT]", "Rebuild specified environment."
    long_desc <<-DESC
      Engine Yard's main configuration run occurs on all servers. Mainly used to fix
      failed configuration of new or existing servers, or to update servers to latest
      Engine Yard stack (e.g. to apply an Engine Yard supplied security
      patch).

      Note that uploaded recipes are also run after the main configuration run has
      successfully completed.
    DESC

    method_option :environment, :type => :string, :aliases => %w(-e),
      :desc => "Environment to rebuild"
    def rebuild
      env = fetch_environment(options[:environment])
      EY.ui.debug("Rebuilding #{env.name}")
      env.rebuild
    end

    desc "rollback [--environment ENVIRONMENT]", "Rollback to the previous deploy."
    long_desc <<-DESC
      Uses code from previous deploy in the "/data/APP_NAME/releases" directory on
      remote server(s) to restart application servers.
    DESC

    method_option :environment, :type => :string, :aliases => %w(-e),
      :desc => "Environment in which to roll back the application"
    method_option :app, :type => :string, :aliases => %w(-a),
      :desc => "Name of the application to roll back"
    method_option :verbose, :type => :boolean, :aliases => %w(-v),
      :desc => "Be verbose"
    def rollback
      app = fetch_app(options[:app])
      env = fetch_environment(options[:environment], app)

      loudly_check_engineyard_serverside(env)

      EY.ui.info("Rolling back '#{app.name}' in '#{env.name}'")
      if env.rollback(app, options[:verbose])
        EY.ui.info "Rollback complete"
      else
        raise EY::Error, "Rollback failed"
      end
    end

    desc "ssh [COMMAND] [--all] [--environment ENVIRONMENT]", "Open an ssh session to the master app server, or run a command."
    long_desc <<-DESC
      If a command is supplied, it will be run, otherwise a session will be
      opened. The application master is used for environments with clusters.
      Option --all requires a command to be supplied and runs it on all servers.

      Note: this command is a bit picky about its ordering. To run a command with arguments on
      all servers, like "rm -f /some/file", you need to order it like so:

      $ #{banner_base} ssh "rm -f /some/file" -e my-environment --all
    DESC
    method_option :environment, :type => :string, :aliases => %w(-e),
      :desc => "Environment to ssh into"
    method_option :all, :type => :boolean, :aliases => %(-a),
      :desc => "Run command on all servers"
    method_option :app_servers, :type => :boolean,
      :desc => "Run command on all application servers"
    method_option :db_servers, :type => :boolean,
      :desc => "Run command on the database servers"
    method_option :db_master, :type => :boolean,
      :desc => "Run command on the master database server"
    method_option :db_slaves, :type => :boolean,
      :desc => "Run command on the slave database servers"
    method_option :utilities, :type => :array, :lazy_default => true,
      :desc => "Run command on the utility servers with the given names. If no names are given, run on all utility servers."

    def ssh(cmd=nil)
      env = fetch_environment_without_app(options[:environment])
      hosts = ssh_hosts(options, env)

      raise NoCommandError.new if cmd.nil? and hosts.count != 1

      hosts.each do |host|
        system "ssh #{env.username}@#{host} #{cmd}"
      end
    end

    no_tasks do
      def ssh_host_filter(opts)
        return lambda {|instance| true }                                                if opts[:all]
        return lambda {|instance| %w(solo app app_master    ).include?(instance.role) } if opts[:app_servers]
        return lambda {|instance| %w(solo db_master db_slave).include?(instance.role) } if opts[:db_servers ]
        return lambda {|instance| %w(solo db_master         ).include?(instance.role) } if opts[:db_master  ]
        return lambda {|instance| %w(db_slave               ).include?(instance.role) } if opts[:db_slaves  ]
        return lambda {|instance| %w(util                   ).include?(instance.role) &&
                                             opts[:utilities].include?(instance.name) } if opts[:utilities  ]
        return lambda {|instance| %w(solo app_master        ).include?(instance.role) }
      end

      def ssh_hosts(opts, env)
        if opts[:utilities] and not opts[:utilities].respond_to?(:include?)
          includes_everything = []
          class << includes_everything
            def include?(*) true end
          end
          filter = ssh_host_filter(opts.merge(:utilities => includes_everything))
        else
          filter = ssh_host_filter(opts)
        end

        instances = env.instances.select {|instance| filter[instance] }
        raise NoInstancesError.new(env.name) if instances.empty?
        return instances.map { |instance| instance.public_hostname }
      end
    end

    desc "logs [--environment ENVIRONMENT]", "Retrieve the latest logs for an environment."
    long_desc <<-DESC
      Displays Engine Yard configuration logs for all servers in the environment. If
      recipes were uploaded to the environment & run, their logs will also be
      displayed beneath the main configuration logs.
    DESC
    method_option :environment, :type => :string, :aliases => %w(-e),
      :desc => "Environment with the interesting logs"
    def logs
      env = fetch_environment(options[:environment])
      env.logs.each do |log|
        EY.ui.info log.instance_name

        if log.main
          EY.ui.info "Main logs for #{env.name}:"
          EY.ui.say  log.main
        end

        if log.custom
          EY.ui.info "Custom logs for #{env.name}:"
          EY.ui.say  log.custom
        end
      end
    end

    desc "recipes", "Commands related to chef recipes."
    subcommand "recipes", EY::CLI::Recipes

    desc "web", "Commands related to maintenance pages."
    subcommand "web", EY::CLI::Web

    desc "version", "Print version number."
    def version
      EY.ui.say %{engineyard version #{EY::VERSION}}
    end
    map ["-v", "--version"] => :version

    desc "help [COMMAND]", "Describe all commands or one specific command."
    def help(*cmds)
      if cmds.empty?
        base = self.class.send(:banner_base)
        list = self.class.printable_tasks

        EY.ui.say "Usage:"
        EY.ui.say "  #{base} [--help] [--version] COMMAND [ARGS]"
        EY.ui.say

        EY.ui.say "Deploy commands:"
        deploy_cmds = %w(deploy environments logs rebuild rollback)
        deploy_cmds.map! do |name|
          list.find{|task| task[0] =~ /^#{base} #{name}/ }
        end
        list -= deploy_cmds

        EY.ui.print_help(deploy_cmds)
        EY.ui.say

        self.class.subcommands.each do |name|
          klass = self.class.subcommand_class_for(name)
          list.reject!{|cmd| cmd[0] =~ /^#{base} #{name}/}
          EY.ui.say "#{name.capitalize} commands:"
          tasks = klass.printable_tasks.reject{|t| t[0] =~ /help$/ }
          EY.ui.print_help(tasks)
          EY.ui.say
        end

        %w(help version).each{|n| list.reject!{|c| c[0] =~ /^#{base} #{n}/ } }
        if list.any?
          EY.ui.say "Other commands:"
          EY.ui.print_help(list)
          EY.ui.say
        end

        self.class.send(:class_options_help, shell)
        EY.ui.say "See '#{base} help COMMAND' for more information on a specific command."
      elsif klass = self.class.subcommand_class_for(cmds.first)
        klass.new.help(*cmds[1..-1])
      else
        super
      end
    end

  end # CLI
end # EY
