require "open3"

module Lookbook
  # Lists files changed in the host app's git working tree, relative to `Rails.root`.
  #
  # @api private
  class McpGitChanges
    REF_PATTERN = /\A[\w\-.\/~^@{}]+\z/

    def initialize(root: Rails.root)
      @root = root.to_s
    end

    # Files changed since `base` (default: the last commit, including staged,
    # unstaged and untracked files).
    #
    # @return [Array<String>] Paths relative to the app root
    def files(base = nil)
      base = base.presence || "HEAD"
      if base.start_with?("-") || !base.match?(REF_PATTERN)
        raise McpToolError, "Invalid git ref: #{base}"
      end

      changed = git("diff", "--name-only", "--relative", base)
      untracked = git("ls-files", "--others", "--exclude-standard")
      (changed + untracked).uniq.sort
    end

    private

    def git(*args)
      output, status = Open3.capture2e("git", *args, chdir: @root)
      raise McpToolError, "git #{args.first} failed: #{output.strip}" unless status.success?

      output.lines.map(&:strip).reject(&:empty?)
    rescue Errno::ENOENT
      raise McpToolError, "git is not available"
    end
  end
end
