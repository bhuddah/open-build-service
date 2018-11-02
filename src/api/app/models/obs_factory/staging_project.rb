module ObsFactory
  # A staging project asociated to a distribution.
  #
  # It contains references to the corresponding Project and
  # Distribution objects.
  class StagingProject
    include ActiveModel::Model
    extend ActiveModel::Naming
    include ActiveModel::Serializers::JSON

    attr_accessor :project, :distribution
    delegate :repositories, to: :project

    NAME_PREFIX = ":Staging:".freeze
    ADI_NAME_PREFIX = ":Staging:adi:".freeze

    # Find all staging projects for a given distribution
    #
    # @param [Boolean] only_letter  only letter stagings, otherwise all stagings
    # @return [Array] array of StagingProject objects
    def self.for(distribution, only_letter = true)
      wildcard = only_letter ? "_" : "%"
      ::Project.where(["name like ?", "#{distribution.root_project_name}#{NAME_PREFIX}#{wildcard}"]).
        map { |project| StagingProject.new(project: project, distribution: distribution) }
    end

    # Find a staging project by distribution and id
    #
    # @return [StagingProject] the project
    def self.find(distribution, id)
      project = ::Project.find_by_name("#{distribution.root_project_name}#{NAME_PREFIX}#{id}")
      if project
        StagingProject.new(project: project, distribution: distribution)
      end
    end

    # Name of the associated project
    #
    # @return [String] name of the Project object
    delegate :name, to: :project

    # Description of the associated project
    #
    # @return [String] description of the Project object
    delegate :description, to: :project

    # Checks if the project is adi staging project
    #
    # @return [Boolean] true if the project is adi staging project
    def adi_staging?
      /#{ADI_NAME_PREFIX}/.match?(name)
    end

    # Part of the name shared by all the staging projects belonging to the same
    # distribution
    #
    # @return [String] the name excluding the id
    def prefix
      if adi_staging?
        "#{distribution.root_project_name}#{ADI_NAME_PREFIX}"
      else
        "#{distribution.root_project_name}#{NAME_PREFIX}"
      end
    end

    # Letter of the staging project, extracted from its name
    #
    # @return [String] just the letter
    def letter
      adi_staging? ? name[prefix.size..-1] : name[prefix.size, 1]
    end

    # Id of the staging project, extracted from its name
    #
    # @return [String] the name excluding the common prefix
    def id
      if adi_staging?
        'adi:' + name[prefix.size..-1]
      else
        name[prefix.size..-1]
      end
    end

    # Requests that are selected into the project but should be not longer valid
    # due to its state (declined, superseded or revoked).
    #
    # @return [ActiveRecord::Relation] Obsolete requests
    def obsolete_requests
      selected_requests.obsolete
    end

    # Packages included in the staging project that are not building properly.
    #
    # Every broken package is represented by a hash with the following keys:
    # 'package', 'state', 'details', 'repository', 'arch'
    #
    # @return [Array] Array of hashes
    def broken_packages
      set_buildinfo if @broken_packages.nil?
      @broken_packages
    end

    # Repositories referenced in the staging project that are still building
    #
    # Every building repository is represented by a hash with the following keys:
    # 'repository', 'arch', 'code', 'state', 'dirty'
    #
    # @return [Array] Array of hashes
    def building_repositories
      set_buildinfo if @building_repositories.nil?
      @building_repositories
    end

    # Requests with open reviews but that are not selected into the staging
    # project
    #
    # @return [Array] Array of Request objects
    def untracked_requests
      open_requests - selected_requests
    end

    # Requests with open reviews
    #
    # @return [Array] Array of BsRequest objects
    def open_requests
      @open_requests ||= BsRequest.with_open_reviews_for(by_project: name)
    end

    # Requests selected in the project
    #
    # @return ActiveRecord::Relation of BsRequest objects
    def selected_requests
      @selected_requests ||= fetch_requests_from_meta
    end

    # Reviews that need to be accepted in order to be able to accept the
    # project.
    #
    # Reviews associated with the project that either are not accepted either
    # have the 'by_project' attribute set to the staging project.
    #
    # @return [Array] array of hashes with the following keys: :id, :state,
    #                 :request, :package and :by.
    def missing_reviews
      if @missing_reviews.nil?
        @missing_reviews = []
        attribs = [:by_group, :by_user, :by_project, :by_package]

        (open_requests + selected_requests).uniq.each do |req|
          req.reviews.each do |rev|
            next if rev.state.to_s == 'accepted' || rev.by_project == name
            # FIXME: this loop (and the inner if) would not be needed
            # if every review only has one valid by_xxx.
            # I'm keeping it to mimic the python implementation.
            # Instead, we could have something like
            # who = rev.by_group || rev.by_user || rev.by_project || rev.by_package
            attribs.each do |att|
              if who = rev.send(att)
                @missing_reviews << { id: rev.id, request: req.number, state: rev.state.to_s, package: req.first_target_package, by: who }
              end
            end
          end
        end
      end
      @missing_reviews
    end

    # Metadata stored in the description field
    #
    # @return [Hash] Hash with the metadata (currently the list of requests)
    def meta
      @meta ||= YAML.safe_load(description.to_s) || {}
    end

    def self.attributes
      ['name', 'description', 'obsolete_requests',
       'building_repositories', 'broken_packages',
       'untracked_requests', 'missing_reviews',
       'selected_requests', 'overall_state',
       'checks', 'missing_checks']
    end

    # Required by ActiveModel::Serializers
    def attributes
      Hash[self.class.attributes.map { |a| [a, nil] }]
    end

    def build_state
      return :building if building_repositories.present?
      return :failed if broken_packages.present?
      :acceptable
    end

    def check_state
      return :testing if missing_checks.present?

      checks.each do |check|
        return :testing if check.pending?
        return :failed if check.failed?
      end

      return :acceptable
    end

    # calculate the overall state of the project
    def overall_state
      return @state unless @state.nil?
      @state = :empty

      if selected_requests.empty?
        return @state
      end

      # base state
      if untracked_requests.present? || obsolete_requests.present?
        @state = :unacceptable
      else
        @state = build_state
      end

      if @state == :acceptable
        @state = check_state
      end

      if @state == :acceptable && missing_reviews.present?
        @state = :review
      end

      @state
    end

    def checks
      fetch_status if @checks.nil?
      @checks
    end

    def missing_checks
      fetch_status if @missing_checks.nil?
      @missing_checks
    end

    protected

    def fetch_status
      @checks = []
      @missing_checks = []
      repositories.each do |repo|
        add_status(repo)
        repo.repository_architectures.each do |repo_arch|
          add_status(repo_arch)
        end
      end
    end

    def add_status(checkable)
      status = checkable.status_reports.latest
      if status
        @missing_checks += status.missing_checks
        @checks += status.checks
      else
        @missing_checks += checkable.required_checks
      end
    end

    # Used internally to calculate #broken_packages and #building_repositories
    def set_buildinfo
      buildresult = Xmlhash.parse(Backend::Api::BuildResults::Status.failed_results(name))
      @broken_packages = []
      @building_repositories = []
      buildresult.elements('result') do |result|
        building = false
        if !['published', 'unpublished'].include?(result['state']) || result['dirty'] == 'true'
          building = true
        end
        result.elements('status') do |status|
          code = status.get('code')
          if ['broken', 'failed'].include?(code) || (code == 'unresolvable' && !building)
            @broken_packages << { 'package' => status['package'],
                                  'project' => name,
                                  'state' => code,
                                  'details' => status['details'],
                                  'repository' => result['repository'],
                                  'arch' => result['arch'] }
          end
        end
        if building
          # determine build summary
          current_repo = result.slice('repository', 'arch', 'code', 'state', 'dirty')
          current_repo[:tobuild] = 0
          current_repo[:final] = 0

          buildresult = Buildresult.find_hashed(project: name, view: 'summary', repository: current_repo['repository'], arch: current_repo['arch'])
          buildresult = buildresult.get('result').get('summary')
          buildresult.elements('statuscount') do |sc|
            if ['excluded', 'broken', 'failed', 'unresolvable', 'succeeded', 'excluded', 'disabled'].include?(sc['code'])
              current_repo[:final] += sc['count'].to_i
            else
              current_repo[:tobuild] += sc['count'].to_i
            end
          end
          @building_repositories << current_repo
        end
      end
      if @building_repositories.present?
        @broken_packages = @broken_packages.reject { |p| p['state'] == 'unresolvable' }
      end
    end

    private

    def fetch_requests_from_meta
      ids = meta["requests"].try(:map) { |i| i['id'] }
      BsRequest.where(number: ids).includes(:reviews, :bs_request_actions)
    end
  end
end
