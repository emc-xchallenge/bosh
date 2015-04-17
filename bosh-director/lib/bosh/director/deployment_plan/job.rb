require 'bosh/director/deployment_plan/job_spec_parser'
require 'bosh/template/property_helper'

module Bosh::Director
  module DeploymentPlan
    class Job
      include Bosh::Template::PropertyHelper

      VALID_LIFECYCLE_PROFILES = %w(service errand)
      DEFAULT_LIFECYCLE_PROFILE = 'service'

      # started, stopped and detached are real states
      # (persisting in DB and reflecting target instance state)
      # recreate and restart are two virtual states
      # (both set  target instance state to "started" and set
      # appropriate instance spec modifiers)
      VALID_JOB_STATES = %w(started stopped detached recreate restart)

      attr_accessor :name
      attr_accessor :lifecycle
      attr_accessor :canonical_name
      attr_accessor :persistent_disk_pool
      attr_accessor :deployment
      attr_accessor :release
      attr_accessor :resource_pool
      attr_accessor :default_network
      attr_accessor :templates
      attr_accessor :properties
      attr_accessor :packages
      attr_accessor :update
      attr_accessor :instances
      attr_accessor :unneeded_instances
      attr_accessor :state
      attr_accessor :instance_states
      attr_accessor :all_properties

      def self.parse(deployment, job_spec, event_log, logger)
        parser = JobSpecParser.new(deployment, event_log, logger)
        parser.parse(job_spec)
      end

      def initialize(deployment)
        @deployment = deployment

        @release = nil
        @templates = []
        @all_properties = nil # All properties available to job
        @properties = nil # Actual job properties

        @instances = []
        @unneeded_instances = []
        @instance_states = {}

        @packages = {}
      end

      def self.is_legacy_spec?(job_spec)
        !job_spec.has_key?("templates")
      end

      # Takes in a job spec and returns a job spec in the new format, if it
      # needs to be modified.  The new format has "templates" key, which is an
      # array with each template's data.  This is used for job collocation,
      # specifically for the agent's current job spec when compared to the
      # director's.  We only convert their template to a single array entry
      # because it should be impossible for the agent to have a job spec with
      # multiple templates in legacy form.
      def self.convert_from_legacy_spec(job_spec)
        return job_spec if !self.is_legacy_spec?(job_spec)
        template = {
          "name" => job_spec["template"],
          "version" => job_spec["version"],
          "sha1" => job_spec["sha1"],
          "blobstore_id" => job_spec["blobstore_id"]
        }
        job_spec["templates"] = [template]
      end

      def spec
        first_template = @templates[0]
        result = {
          "name" => @name,
          "templates" => [],
          # --- Legacy ---
          "template" => first_template.name,
          "version" => first_template.version,
          "sha1" => first_template.sha1,
          "blobstore_id" => first_template.blobstore_id
        }
        if first_template.logs
          result["logs"] = first_template.logs
        end
        # --- /Legacy ---

        @templates.each do |template|
          template_entry = {
            "name" => template.name,
            "version" => template.version,
            "sha1" => template.sha1,
            "blobstore_id" => template.blobstore_id
          }
          if template.logs
            template_entry["logs"] = template.logs
          end
          result["templates"] << template_entry
        end

        result
      end

      # Returns package specs for all packages in the job indexed by package
      # name. To be used by all instances of the job to populate agent state.
      def package_spec
        result = {}
        @packages.each do |name, package|
          result[name] = package.spec
        end

        result.select { |name, _| run_time_dependencies.include? name }
      end

      # Returns job instance by index
      def instance(index)
        @instances[index]
      end

      # Returns the state state of job instance by its index
      def instance_state(index)
        @instance_states[index] || @state
      end

      # Registers compiled package with this job.
      def use_compiled_package(compiled_package_model)
        compiled_package = CompiledPackage.new(compiled_package_model)
        @packages[compiled_package.name] = compiled_package
      end

      # Extracts only the properties needed by this job. This is decoupled from
      # parsing properties because templates need to be bound to their models
      # before 'bind_properties' is being called (as we persist job template
      # property definitions in DB).
      def bind_properties
        @properties = filter_properties(@all_properties)
      end

      def validate_package_names_do_not_collide!
        releases_by_package_names = templates
          .reduce([]) { |memo, t| memo + t.model.package_names.product([t.release]) }
          .reduce({}) { |memo, package_name_and_release_version|
            package_name = package_name_and_release_version.first
            release_version = package_name_and_release_version.last
            memo[package_name] ||= Set.new
            memo[package_name] << release_version
            memo
          }

        releases_by_package_names.each do |package_name, releases|
          if releases.size > 1
            release1, release2 = releases.to_a[0..1]
            offending_template1 = templates.find { |t| t.release == release1 }
            offending_template2 = templates.find { |t| t.release == release2 }

            raise JobPackageCollision,
                  "Package name collision detected in job `#{@name}': "\
                  "template `#{release1.name}/#{offending_template1.name}' depends on package `#{release1.name}/#{package_name}', "\
                  "template `#{release2.name}/#{offending_template2.name}' depends on `#{release2.name}/#{package_name}'. " +
                  'BOSH cannot currently collocate two packages with identical names from separate releases.'
          end
        end
      end

      def bind_unallocated_vms
        instances.each do |instance|
          instance.bind_unallocated_vm

          # Now that we know every VM has been allocated and
          # instance models are bound, we can sync the state.
          instance.sync_state_with_db
        end
      end

      def bind_instance_networks
        instances.each do |instance|
          instance.network_reservations.each do |net_name, reservation|
            unless reservation.reserved?
              network = @deployment.network(net_name)
              network.reserve!(reservation, "`#{name}/#{instance.index}'")
              instance.vm.use_reservation(reservation) if instance.vm
            end
          end
        end
      end

      def starts_on_deploy?
        @lifecycle == 'service'
      end

      def can_run_as_errand?
        @lifecycle == 'errand'
      end

      # reverse compatibility: translate disk size into a disk pool
      def persistent_disk=(disk_size)
        disk_pool = DiskPool.new(SecureRandom.uuid)
        disk_pool.disk_size = disk_size
        @persistent_disk_pool = disk_pool
      end

      private

      # @param [Hash] collection All properties collection
      # @return [Hash] Properties required by templates included in this job
      def filter_properties(collection)
        if @templates.empty?
          raise DirectorError, "Can't extract job properties before parsing job templates"
        end

        if @templates.none? { |template| template.properties }
          return collection
        end

        if @templates.all? { |template| template.properties }
          return extract_template_properties(collection)
        end

        raise JobIncompatibleSpecs,
          "Job `#{name}' has specs with conflicting property definition styles between" +
          " its job spec templates.  This may occur if colocating jobs, one of which has a spec file including" +
          " `properties' and one which doesn't."
      end

      def extract_template_properties(collection)
        result = {}

        @templates.each do |template|
          template.properties.each_pair do |name, definition|
            copy_property(result, collection, name, definition["default"])
          end
        end

        result
      end

      def run_time_dependencies
        templates.flat_map { |template| template.package_models }.uniq.map(&:name)
      end
    end
  end
end
