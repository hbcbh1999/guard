require "thread"
require "listen"

require "guard/config"
require "guard/deprecated/guard" unless Guard::Config.new.strict?

require "guard/internals/debugging"
require "guard/internals/traps"
require "guard/internals/helpers"

require "guard/metadata"
require "guard/options"

require "guard/commander"
require "guard/dsl"
require "guard/group"
require "guard/interactor"
require "guard/notifier"
require "guard/plugin_util"
require "guard/runner"
require "guard/sheller"
require "guard/ui"
require "guard/watcher"
require "guard/guardfile/evaluator"

# Guard is the main module for all Guard related modules and classes.
# Also Guard plugins should use this namespace.
#
module Guard
  Deprecated::Guard.add_deprecated(self) unless Config.new.strict?

  class << self
    attr_reader :listener

    include Internals::Helpers

    # Initializes the Guard singleton:
    #
    # * Initialize the internal Guard state;
    # * Create the interactor
    # * Select and initialize the file change listener.
    #
    # @option options [Boolean] clear if auto clear the UI should be done
    # @option options [Boolean] notify if system notifications should be shown
    # @option options [Boolean] debug if debug output should be shown
    # @option options [Array<String>] group the list of groups to start
    # @option options [Array<String>] watchdir the directories to watch
    # @option options [String] guardfile the path to the Guardfile
    #
    # @return [Guard] the Guard singleton
    #

    # TODO: this method has too many instance variables
    # and some are mock and leak between tests,
    # so ideally there should be a guard "instance"
    # object that can be created anew between tests
    def setup(cmdline_options = {})
      init(cmdline_options)

      @queue = Queue.new
      self.watchdirs = Array(options[:watchdir])

      UI.reset_and_clear

      reset_plugins
      reset_scope

      _evaluate
      setup_scope


      @listener = _setup_listener

      Notifier.connect(notify: options[:notify])

      traps = Internals::Traps
      traps.handle("USR1") { async_queue_add([:guard_pause, :paused]) }
      traps.handle("USR2") { async_queue_add([:guard_pause, :unpaused]) }

      @interactor = Interactor.new(options[:no_interactions])
      traps.handle("INT") { @interactor.handle_interrupt }

      self
    end

    attr_reader :interactor

    # Used only by tests (for all I know...)
    def clear_options
      @options = nil
    end

    # Initializes the plugins array to an empty array.
    #
    # @see Guard.plugins
    #
    def reset_plugins
      @plugins = []
    end

    attr_reader :watchdirs

    # Stores the scopes defined by the user via the `--group` / `-g` option (to
    # run only a specific group) or the `--plugin` / `-P` option (to run only a
    # specific plugin).
    #
    # @see CLI#start
    # @see Dsl#scope
    #
    def setup_scope(new_scope = {})
      # TODO: there should be a special Scope class instead
      new_scope = _prepare_scope(new_scope)

      Guard.scope = {
        groups: new_scope[:groups].map { |item| add_group(item) },
        plugins: new_scope[:plugins].map { |item| plugin(item) },
      }
    end

    # Asynchronously trigger changes
    #
    # Currently supported args:
    #
    #   old style hash: {modified: ['foo'], added: ['bar'], removed: []}
    #
    #   new style signals with args: [:guard_pause, :unpaused ]
    #
    def async_queue_add(changes)
      @queue << changes

      # Putting interactor in background puts guard into foreground
      # so it can handle change notifications
      Thread.new { interactor.background }
    end

    def pending_changes?
      ! @queue.empty?
    end

    def watchdirs=(dirs)
      dirs = [Dir.pwd] if dirs.empty?
      @watchdirs = dirs.map { |dir| File.expand_path dir }
    end

    private

    # Initializes the listener and registers a callback for changes.
    #
    def _setup_listener
      if options[:listen_on]
        Listen.on(options[:listen_on], &_listener_callback)
      else
        listener_options = {}
        [:latency, :force_polling, :wait_for_delay].each do |option|
          listener_options[option] = options[option] if options[option]
        end
        listen_args = watchdirs + [listener_options]
        Listen.to(*listen_args, &_listener_callback)
      end
    end

    # Process the change queue, running tasks within the main Guard thread
    def _process_queue
      actions, changes = [], { modified: [], added: [], removed: [] }

      while pending_changes?
        if (item = @queue.pop).first.is_a?(Symbol)
          actions << item
        else
          item.each { |key, value| changes[key] += value }
        end
      end

      _run_actions(actions)
      return if changes.values.all?(&:empty?)
      Runner.new.run_on_changes(*changes.values)
    end

    # TODO: Guard::Watch or Guard::Scope should provide this
    def _scoped_watchers
      watchers = []
      Runner.new.send(:_scoped_plugins) { |guard| watchers += guard.watchers }
      watchers
    end

    # Check if any of the changes are actually watched for
    def _relevant_changes?(changes)
      files = changes.values.flatten(1)
      watchers = _scoped_watchers
      watchers.any? { |watcher| files.any? { |file| watcher.match(file) } }
    end

    def _relative_pathnames(paths)
      paths.map { |path| _relative_pathname(path) }
    end

    def _run_actions(actions)
      actions.each do |action_args|
        args = action_args.dup
        namespaced_action = args.shift
        action = namespaced_action.to_s.sub(/^guard_/, "")
        if ::Guard.respond_to?(action)
          ::Guard.send(action, *args)
        else
          fail "Unknown action: #{action.inspect}"
        end
      end
    end

    def _listener_callback
      lambda do |modified, added, removed|
        relative_paths = {
          modified: _relative_pathnames(modified),
          added: _relative_pathnames(added),
          removed: _relative_pathnames(removed)
        }

        async_queue_add(relative_paths) if _relevant_changes?(relative_paths)
      end
    end

    # TODO: obsoleted? (by Dsl errors)
    def _pluginless_guardfile?
      # no Reevaluator means there was no Guardfile configured that could be
      # reevaluated, so we don't have a pluginless guardfile, because we don't
      # have a Guardfile to begin with...
      #
      # But, if we have a Guardfile, we'll at least have the built-in
      # Reevaluator, so the following will work:

      # TODO: this is a workaround for tests
      return true if plugins.empty?

      plugins.map(&:name) == ["reevaluator"]
    end

    def _evaluate
      evaluator = Guardfile::Evaluator.new(Guard.options)
      evaluator.evaluate
      msg = "No plugins found in Guardfile, please add at least one."
      UI.error msg if _pluginless_guardfile?

      if evaluator.inline?
        UI.info("Using inline Guardfile.")
      elsif evaluator.custom?
        UI.info("Using Guardfile at #{ evaluator.path }.")
      end
    rescue Guardfile::Evaluator::NoPluginsError => e
      UI.error(e.message)
    end
  end
end
