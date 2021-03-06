require "digest/md5"

require "log4r"

module VagrantPlugins
  module Puppet
    module Provisioner
      class PuppetError < Vagrant::Errors::VagrantError
        error_namespace("vagrant.provisioners.puppet")
      end

      class Puppet < Vagrant.plugin("2", :provisioner)
        def initialize(machine, config)
          super

          @logger = Log4r::Logger.new("vagrant::provisioners::puppet")
        end

        def configure(root_config)
          # Calculate the paths we're going to use based on the environment
          root_path = @machine.env.root_path
          @expanded_module_paths   = @config.expanded_module_paths(root_path)
          @manifest_file           = File.join(manifests_guest_path, @config.manifest_file)

          # Setup the module paths
          @module_paths = []
          @expanded_module_paths.each_with_index do |path, _|
            key = Digest::MD5.hexdigest(path.to_s)
            @module_paths << [path, File.join(config.temp_dir, "modules-#{key}")]
          end

          folder_opts = {}
          folder_opts[:type] = @config.synced_folder_type if @config.synced_folder_type
          folder_opts[:owner] = "root" if !@config.synced_folder_type

          # Share the manifests directory with the guest
          if @config.manifests_path[0].to_sym == :host
            root_config.vm.synced_folder(
              File.expand_path(@config.manifests_path[1], root_path),
              manifests_guest_path, folder_opts)
          end

          # Share the module paths
          @module_paths.each do |from, to|
            root_config.vm.synced_folder(from, to, folder_opts)
          end
        end

        def provision
          # If the machine has a wait for reboot functionality, then
          # do that (primarily Windows)
          if @machine.guest.capability?(:wait_for_reboot)
            @machine.guest.capability(:wait_for_reboot)
          end

          # Check that the shared folders are properly shared
          check = []
          if @config.manifests_path[0] == :host
            check << manifests_guest_path
          end
          @module_paths.each do |host_path, guest_path|
            check << guest_path
          end

          # Make sure the temporary directory is properly set up
          @machine.communicate.tap do |comm|
            comm.sudo("mkdir -p #{config.temp_dir}")
            comm.sudo("chmod 0777 #{config.temp_dir}")
          end

          verify_shared_folders(check)

          # Verify Puppet is installed and run it
          verify_binary("puppet")

          # Upload Hiera configuration if we have it
          @hiera_config_path = nil
          if config.hiera_config_path
            local_hiera_path   = File.expand_path(config.hiera_config_path,
              @machine.env.root_path)
            @hiera_config_path = File.join(config.temp_dir, "hiera.yaml")
            @machine.communicate.upload(local_hiera_path, @hiera_config_path)
          end

          run_puppet_apply
        end

        def manifests_guest_path
          if config.manifests_path[0] == :host
            # The path is on the host, so point to where it is shared
            key = Digest::MD5.hexdigest(config.manifests_path[1])
            File.join(config.temp_dir, "manifests-#{key}")
          else
            # The path is on the VM, so just point directly to it
            config.manifests_path[1]
          end
        end

        def verify_binary(binary)
          @machine.communicate.sudo(
            "which #{binary}",
            error_class: PuppetError,
            error_key: :not_detected,
            binary: binary)
        end

        def run_puppet_apply
          default_module_path = "/etc/puppet/modules"
          if windows?
            default_module_path = "/ProgramData/PuppetLabs/puppet/etc/modules"
          end

          options = [config.options].flatten
          module_paths = @module_paths.map { |_, to| to }
          if !@module_paths.empty?
            # Append the default module path
            module_paths << default_module_path

            # Add the command line switch to add the module path
            module_path_sep = windows? ? ";" : ":"
            options << "--modulepath '#{module_paths.join(module_path_sep)}'"
          end

          if @hiera_config_path
            options << "--hiera_config=#{@hiera_config_path}"
          end

          if !@machine.env.ui.is_a?(Vagrant::UI::Colored)
            options << "--color=false"
          end

          options << "--manifestdir #{manifests_guest_path}"
          options << "--detailed-exitcodes"
          options << @manifest_file
          options = options.join(" ")

          # Build up the custom facts if we have any
          facter = ""
          if !config.facter.empty?
            facts = []
            config.facter.each do |key, value|
              facts << "FACTER_#{key}='#{value}'"
            end

            # If we're on Windows, we need to use the PowerShell style
            if windows?
              facts.map! { |v| "`$env:#{v};" }
            end

            facter = "#{facts.join(" ")} "
          end

          command = "#{facter}puppet apply #{options}"
          if config.working_directory
            if windows?
              command = "cd #{config.working_directory}; if (`$?) \{ #{command} \}"
            else
              command = "cd #{config.working_directory} && #{command}"
            end
          end

          @machine.ui.info(I18n.t(
            "vagrant.provisioners.puppet.running_puppet",
            manifest: config.manifest_file))

          opts = {
            elevated: true,
            error_class: Vagrant::Errors::VagrantError,
            error_key: :ssh_bad_exit_status_muted,
            good_exit: [0,2],
          }
          @machine.communicate.sudo(command, opts) do |type, data|
            if !data.chomp.empty?
              @machine.ui.info(data.chomp)
            end
          end
        end

        def verify_shared_folders(folders)
          folders.each do |folder|
            @logger.debug("Checking for shared folder: #{folder}")
            if !@machine.communicate.test("test -d #{folder}", sudo: true)
              raise PuppetError, :missing_shared_folders
            end
          end
        end

        def windows?
          @machine.config.vm.communicator == :winrm
        end
      end
    end
  end
end
