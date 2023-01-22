# frozen_string_literal: true

module Ballantine
  class Repository
    # reference: https://github.com/desktop/desktop/blob/a7bca44088b105a04714dc4628f4af50f6f179c3/app/src/lib/remote-parsing.ts#L27-L44
    GITHUB_REGEXES = [
      '^https?://(.+)/(.+)/(.+)\.git/?$', # protocol: https -> https://github.com/oohyun15/ballantine.git | https://github.com/oohyun15/ballantine.git/
      '^https?://(.+)/(.+)/(.+)/?$',      # protocol: https -> https://github.com/oohyun15/ballantine | https://github.com/oohyun15/ballantine/
      '^git@(.+):(.+)/(.+)\.git$',        # protocol: ssh   -> git@github.com:oohyun15/ballantine.git
      '^git@(.+):(.+)/(.+)/?$',           # protocol: ssh   -> git@github.com:oohyun15/ballantine | git@github.com:oohyun15/ballantine/
      '^git:(.+)/(.+)/(.+)\.git$',        # protocol: ssh   -> git:github.com/oohyun15/ballantine.git
      '^git:(.+)/(.+)/(.+)/?$',           # protocol: ssh   -> git:github.com/oohyun15/ballantine | git:github.com/oohyun15/ballantine/
      '^ssh://git@(.+)/(.+)/(.+)\.git$',  # protocol: ssh   -> ssh://git@github.com/oohyun15/ballantine.git
    ].freeze
    FILE_GITMODULES = ".gitmodules"

    attr_reader :name, :path, :owner, :url, :from, :to # attributes
    attr_reader :main_repo, :sub_repos, :commits # associations

    class << self
      # @param [String] path
      # @return [Repository]
      def find_or_create_by(path:)
        @_collections = {} unless defined?(@_collections)
        return @_collections[path] unless @_collections[path].nil?

        @_collections[path] = new(path:)
      end

      # @return [Array<Repository>]
      def all
        return [] unless defined?(@_collections)

        @_collections.values
      end
    end

    # @param [String] path
    def initialize(path:)
      Dir.chdir(path)
      @path = path
      @commits = []
      @sub_repos = retrieve_sub_repos
      @owner, @name = GITHUB_REGEXES.each do |regex|
        str = %x(git config --get remote.origin.url).chomp.match(regex)
        break [str[2], str[3]] if str
      end
      @url = "https://github.com/#{owner}/#{name}"
    end

    # @param [String] target
    # @param [String] source
    # @return [String]
    def init_variables(target, source)
      current_revision = %x(git rev-parse --abbrev-ref HEAD).chomp

      foo = lambda do |hash, context|
        hash = check_tag(hash)
        system("git checkout #{hash} -f &> /dev/null")
        system("git pull &> /dev/null")

        hash = %x(git --no-pager log -1 --format='%h').chomp
        commit = Commit.find_or_create_by(
          hash: hash,
          repo: self,
        )
        instance_variable_set("@#{context}", commit)

        if sub_repos.any?
          %x(git ls-tree HEAD #{sub_repos.map(&:path).join(" ")}).split("\n").map do |line|
            _, _, sub_hash, sub_path = line.split(" ")
            sub_repo = Repository.find_or_create_by(
              path: path + "/" + sub_path,
            )
            sub_commit = Commit.find_or_create_by(
              hash: sub_hash,
              repo: sub_repo,
            )
            sub_repo.instance_variable_set("@#{context}", sub_commit)
          end
        end
      end

      foo.call(target, "from")
      foo.call(source, "to")

      system("git checkout #{current_revision} -f &> /dev/null")

      true
    end

    private

    # @param [String] name
    # @return [String] hash
    def check_tag(name)
      list = %x(git tag -l).split("\n")
      return name unless list.grep(name).any?

      system("git fetch origin tag #{name} -f &> /dev/null")
      %x(git rev-list -n 1 #{name}).chomp[0...7]
    end

    # @return [Array<Repository>]
    def retrieve_sub_repos
      return [] unless Dir[FILE_GITMODULES].any?

      file = File.open(FILE_GITMODULES)
      lines = file.readlines.map(&:chomp)
      file.close
      repos = lines.grep(/path =/).map do |line|
        repo = Repository.find_or_create_by(
          path: path + "/" + line[/(?<=path \=).*/, 0].strip,
        )
        repo.main_repo = self
        repo
      end

      # NOTE: current directory is changed to submodule repository path after initialize, so chdir to current `path`.
      Dir.chdir(path)

      repos
    end
  end
end
