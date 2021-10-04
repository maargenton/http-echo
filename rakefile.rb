# =============================================================================
#
# MODULE      : rakefile.rb
# PROJECT     : http-echo
# DESCRIPTION :
#
# Copyright (c) 2016-2021, Marc-Antoine Argenton.  All rights reserved.
# =============================================================================

require 'fileutils'

task default: [:test, :build]


desc 'Display build information'
task :info do
    puts "Module:  #{GoBuild.default.gomod}"
    puts "Version: #{GoBuild.default.version}"
    puts "Source:  #{BuildInfo.default.remote}/tree/#{BuildInfo.default.commit}"
    puts "Image name:  #{File.basename(GoBuild.default.gomod)}"
    puts "Main target: bin/#{GoBuild.default.main_target}"

    if GoBuild.default.targets.count > 1 then
        puts "Additional targels:"
        puts (GoBuild.default.targets.keys - [GoBuild.default.main_target]).map { |t|
            "  - bin/#{t}" }.join(" \n")
    end
end


desc 'Display inferred build version string'
task :version do
    puts GoBuild.default.version
end


desc 'Run all local tests, with coverage analysis'
task :test do
    system "go test -cover -race ./..."
    exit($?.exitstatus) if $?.exitstatus != 0
end


desc 'Build all module binaries into a ./bin folder'
task :build do
    FileUtils.makedirs( './bin' )
    GoBuild.default.commands.each do |name, cmd|
        puts "Building #{name} ..."
        puts cmd
        system cmd
        exit($?.exitstatus) if $?.exitstatus != 0
    end
end


desc 'Build a docker image containing the built binaries'
task :'build-image' do
    image_name = File.basename(GoBuild.default.gomod)
    image_version = BuildInfo.default.version
    entry_point = "/bin/#{GoBuild.default.main_target}"
    commands = GoBuild.default.commands()
    dockerfile = <<END
        FROM golang:1.17.1-alpine3.14 AS builder
        RUN apk add build-base git
        WORKDIR /src/
        COPY ./ .
        RUN env
        RUN go env
        RUN go test -v -cover ./...
        #{commands.map {|name, cmd| "RUN #{cmd}"}.join("\n\n")}

        FROM alpine:3.14.2
        RUN apk --no-cache add ca-certificates
        COPY --from=builder /src/bin/ /bin
        ENTRYPOINT ["#{entry_point}"]
END
    tag = "#{image_name}:#{image_version}"
    registry_tags = docker_registry_tags(tag).compact()
    tags = ([tag] + registry_tags).map { |t| "-t #{t}" }.join(' ')

    puts "|docker build #{tags} -f - ."
    puts dockerfile
    open("|docker build #{tags} -f - .", 'w') { |f| f.puts dockerfile }
    exit($?.exitstatus) if $?.exitstatus != 0

    success = registry_tags.map do |tag|
        puts "Pushing #{tag} ..."
        system "docker push #{tag}"
        $?.exitstatus == 0
    end
    if !success.all?
        puts "Failed to push image to at least one registry"
        exit(1)
    end
end


desc 'Run the main target command'
task :run do
    cmd = GoBuild.default.commands('run')[GoBuild.default.main_target]
    puts cmd
    system cmd
    exit($?.exitstatus) if $?.exitstatus != 0
end


desc 'Remove build artifacts'
task :clean do
    FileUtils.rm_rf('./bin')
end



# ----------------------------------------------------------------------------
# BuildInfo : Helper to extract version inforrmation for git repo
# ----------------------------------------------------------------------------

class BuildInfo
    class << self
        def default() return @default ||= new end
    end

    def initialize()
        if _git('rev-parse --is-shallow-repository') == 'true'
            puts "Fetching missing information from remote ..."
            system(' git fetch --prune --tags --unshallow')
        end
    end

    def name()      return @name    ||= _name()     end
    def version()   return @version ||= _version()  end
    def remote()    return @remote  ||= _remote()   end
    def commit()    return @commit  ||= _commit()   end
    def dir()       return @dir     ||= _dir()      end

    private
    def _git( cmd ) return `git #{cmd} 2>/dev/null`.strip()     end
    def _commit()   return _git('rev-parse HEAD')               end
    def _dir()      return _git('rev-parse --show-toplevel')    end

    def _name()
        remote_basename = File.basename(remote() || "" )
        return remote_basename if remote_basename != ""
        return File.basename(File.expand_path("."))
    end

    def _version()
        v, b, n, g = _info()                    # Extract base info from git branch and tags
        m = _mtag()                             # Detect locally modified files
        v = _patch(v) if n > 0 || !m.nil?       # Increment patch if needed to to preserve semver orderring
        b = 'rc' if _is_default_branch(b, v)    # Rename branch to 'rc' for default branch
        return v if b == 'rc' && n == 0 && m.nil?
        return "#{v}-" + [b, n, g, m].compact().join('.')
    end

    def _info()
        # Note: Due to glob(7) limitations, the following pattern enforces
        # 3-part dot-separated sequences starting with a digit,
        # rather than 3 dot-separated numbers.
        d = _git("describe --always --tags --long  --match 'v[0-9]*.[0-9]*.[0-9]*'").strip.split('-')
        if d.count != 0
            b = _git("rev-parse --abbrev-ref HEAD").strip.gsub(/[^A-Za-z0-9\._-]+/, '-')
            return ['v0.0.0', b, _git("rev-list --count HEAD").strip.to_i, "g#{d[0]}"] if d.count == 1
            return [d[0], b, d[1].to_i, d[2]] if d.count == 3
        end
        return ['v0.0.0', "none", 0, 'g0000000']
    end

    def _is_default_branch(b, v)
        # Check branch name against common main branch names, and branch name
        # that matches the beginning of the version strings e.g. 'v1' is
        # considered a default branch for version 'v1.x.y'.
        return ["main", "master", "HEAD"].include?(b) ||
            (!v.nil? && v.start_with?(b))
    end

    def _patch(v)
        # Increment the patch number by 1, so that intermediate version strings
        # sort between the last tag and the next tag according to semver.
        #   v0.6.1
        #       v0.6.1-maa-cleanup.1.g6ede8cd   <-- with _patch()
        #   v0.6.0
        #       v0.6.0-maa-cleanup.1.g6ede8cd   <-- without _patch()
        #   v0.5.99
        vv = v[1..-1].split('.').map { |v| v.to_i }
        vv[-1] += 1
        v = "v" + vv.join(".")
        return v
    end

    def _mtag()
        # Generate a `.mXXXXXXXX` fragment based on latest mtime of modified
        # files in the index. Returns `nil` if no files are locally modified.
        status = _git("status --porcelain=2 --untracked-files=no")
        files = status.lines.map {|l| l.strip.split(/ +/).last }.map { |n| n.split(/\t/).first }
        t = files.map { |f| File.mtime(f).to_i rescue nil }.compact.max
        return t.nil? ? nil : "m%08x" % t
    end

    GIT_SSH_REPO = /git@(?<host>[^:]+):(?<path>.+).git/
    def _remote()
        remote = _git('remote get-url origin')
        m = GIT_SSH_REPO.match(remote)
        return remote if m.nil?

        host = m[:host]
        host = "github.com" if host.end_with? ("github.com")
        return "https://#{host}/#{m[:path]}/"
    end
end



# ----------------------------------------------------------------------------
# GoBuild : Helper to build go projects
# ----------------------------------------------------------------------------

class GoBuild
    class << self
        def default() return @default ||= new end
    end

    def initialize( buildinfo = nil )
        @buildinfo = buildinfo || BuildInfo.default
    end

    def gomod()         return @gomod       ||= _gomod()            end
    def targets()       return @tagets      ||= _targets()          end
    def main_target()   return @main_target ||= _main_target()      end
    def version()       return @version     ||= @buildinfo.version  end
    def ldflags()       return @ldflags     ||= _ldflags()          end

    def commands(action = 'build')
        flags = %Q{"#{ldflags}"}
        Hash[targets.map do |name, input|
            output = File.join( './bin', name )
            cmd = [ "go #{action} -trimpath -ldflags #{flags}",
                ("-o #{output}" if action == 'build'),
                "#{input}"
            ].compact.join(' ')
            [name, cmd]
        end]
    end

private
    def _gomod()
        return '' if !File.readable?('go.mod')
        File.foreach('go.mod') do |l|
            return l[7..-1].strip if l.start_with?( 'module ' )
        end
    end

    def _targets()
        Hash[Dir["./cmd/**/main.go"].map do |f|
            path = File.dirname(f)
            [File.basename(path), File.join( path, "..." )]
        end]
    end

    def _ldflags()
        prefix = "#{gomod}/pkg/buildinfo"
        {   Version: @buildinfo.version,
            GitHash: @buildinfo.commit,
            GitRepo: @buildinfo.remote,
            BuildRoot: @buildinfo.dir
        }.map { |k,v| "-X #{prefix}.#{k}=#{v}"}.join(' ')
    end

    def _main_target()
        mod = File.basename(gomod)
        targets.keys.min_by{ |v| _lev(v, mod)}
    end

    def _lev(a, b, memo={})
        return b.size if a.empty?
        return a.size if b.empty?
        return memo[[a, b]] ||= [
            _lev(a.chop, b, memo) + 1,
            _lev(a, b.chop, memo) + 1,
            _lev(a.chop, b.chop, memo) + (a[-1] == b[-1] ? 0 : 1)
        ].min
    end
end



# ----------------------------------------------------------------------------
# DockerHelper : Helper to build go projects
# ----------------------------------------------------------------------------

def docker_registry_tags(base_tag)
    return [github_registry_tag(base_tag)]
end

def github_registry_tag(base_tag)
    return if ENV['GITHUB_ACTOR'].nil? || ENV['GITHUB_REPOSITORY'].nil?
    if ENV['GITHUB_TOKEN'].nil? then
        puts "Found GitHub Actiona context but no 'GITHUB_TOKEN'."
        puts "Image will not be pushed to GitHub package registry."
        puts "To resolve this issue, add the following to your workflow:"
        puts "  env:"
        puts "    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}"
        return
    end
    # Authenticate
    puts "Authenticating with docker.pkg.github.com..."
    system("echo ${GITHUB_TOKEN} | docker login docker.pkg.github.com --username ${GITHUB_ACTOR} --password-stdin")
    puts "Failed to authenticate with docker.pkg.github.com" if $?.exitstatus != 0

    return File.join('docker.pkg.github.com', ENV['GITHUB_REPOSITORY'], base_tag)
end



# ----------------------------------------------------------------------------
# Release notes generator
# ----------------------------------------------------------------------------

def generate_release_notes(version, prefix:nil, input:nil, checksums:nil)
    rn = ""
    rn += "#{prefix} #{version}\n\n" if prefix
    rn += load_release_notes(input, version) if input
    rn += "\n## Checksums\n\n```\n" + File.read(checksums) + "```\n" if checksums
    rn
end

def load_release_notes(filename, version)
    notes, capture = [], false
    File.readlines(filename).each do |l|
        if l.start_with?( "# ")
            break if capture
            capture = true if version.start_with?(l[2..-1].strip())
        elsif capture
            notes << l
        end
    end
    notes.shift while (notes.first || "-").strip == ""
    return notes.join()
end



# ----------------------------------------------------------------------------
# Definitions to help formating 'rake watch' results
# ----------------------------------------------------------------------------

TERM_WIDTH = `tput cols`.to_i || 80

def tty_red(str);           "\e[31m#{str}\e[0m" end
def tty_green(str);         "\e[32m#{str}\e[0m" end
def tty_blink(str);         "\e[5m#{str}\e[25m" end
def tty_reverse_color(str); "\e[7m#{str}\e[27m" end

def print_separator( success = true )
    if success
        puts tty_green( "-" * TERM_WIDTH )
    else
        puts tty_reverse_color(tty_red( "-" * TERM_WIDTH ))
    end
end



# ----------------------------------------------------------------------------
# Definition of watch task, that monitors the project folder for any relevant
# file change and runs the unit test of the project.
# ----------------------------------------------------------------------------

def watch( *glob )
    yield unless block_given?
    files = []
    loop do
        new_files = Dir[*glob].map {|file| File.mtime(file) }
        yield if new_files != files
        files = new_files
        sleep 0.5
    end
end

desc 'Run unit tests everytime a source or test file is changed'
task :'watch-test' do
    watch( '**/*.go' ) do
        success = system "clear && rake test"
        print_separator( success )
    end
end

desc 'Run unit tests everytime a source or test file is changed'
task :'watch-run' do
    watch( '**/*.go' ) do
        success = system "clear && rake run"
        print_separator( success )
    end
end

task watch: [:'watch-test']
