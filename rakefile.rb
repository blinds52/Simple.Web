include FileTest

# Build information
SOLUTION_NAME = "Simple.Web"
SOLUTION_DESC = "A REST-focused, object-oriented Web Framework for .NET 4."
SOLUTION_LICENSE = "http://www.opensource.org/licenses/mit-license.php"
SOLUTION_URL = "http://github.com/markrendle/Simple.Web"
SOLUTION_COMPANY = "Mark Rendle"
SOLUTION_COPYRIGHT = "Copyright (C) #{SOLUTION_COMPANY} 2012"

# Build configuration
load "VERSION.txt"

CONFIG = ENV["config"] || "Release"
PLATFORM = ENV["platform"] || "x86"
BUILD_NUMBER = "#{BUILD_VERSION}.#{(ENV["BUILD_NUMBER"] || Time.new.strftime('5%H%M'))}"
MONO = (RUBY_PLATFORM.downcase.include?('linux') or RUBY_PLATFORM.downcase.include?('darwin'))
TEAMCITY = (!ENV["BUILD_NUMBER"].nil? or !ENV["TEAMCITY_BUILD_PROPERTIES_FILE"].nil?)

# NuGet configuration
NUGET_APIKEY_LOCAL = ENV["apikey_local"]
NUGET_APIURL_LOCAL = ENV["apiurl_local"]
NUGET_APIKEY_REMOTE = ENV["apikey_remote"]
NUGET_APIURL_REMOTE = ENV["apiurl_remote"]

# Paths
BASE_PATH = File.expand_path(File.dirname(__FILE__))
SOURCE_PATH = "#{BASE_PATH}/src"
TESTS_PATH = "#{BASE_PATH}/src"
SPECS_PATH = "#{BASE_PATH}/specs"
BUILD_PATH = "#{BASE_PATH}/build"
RESULTS_PATH = "#{BASE_PATH}/results"
ARTIFACTS_PATH = "#{BASE_PATH}/artifacts"
NUSPEC_PATH = "#{BASE_PATH}/packaging/nuspec"
NUGET_PATH = "#{BUILD_PATH}/nuget"
TOOLS_PATH = "#{BASE_PATH}/tools"

# Files
ASSEMBLY_INFO = "#{SOURCE_PATH}/CommonAssemblyInfo.cs"
SOLUTION_FILE = "#{SOURCE_PATH}/Simple.Web.sln"
VERSION_INFO = "#{BASE_PATH}/VERSION.txt"

# Matching
TEST_ASSEMBLY_PATTERN_PREFIX = ".Tests"
TEST_ASSEMBLY_PATTERN_UNIT = "#{TEST_ASSEMBLY_PATTERN_PREFIX}.Unit"
TEST_ASSEMBLY_PATTERN_INTEGRATION = "#{TEST_ASSEMBLY_PATTERN_PREFIX}.Integration"
SPEC_ASSEMBLY_PATTERN = ".Specs"

# Commands
XUNIT_COMMAND = "#{TOOLS_PATH}/xUnit/xunit.console.clr4.#{(PLATFORM.empty? or PLATFORM.eql?('x86') ? 'x86' : '')}.exe"
MSPEC_COMMAND = "#{TOOLS_PATH}/mspec/mspec.exe"
NUGET_COMMAND = "#{TOOLS_PATH}/nuget/nuget.exe"

# Set up our build system
require 'albacore'
require 'pathname'
require 'rake/clean'
require 'rexml/document'

# Configure albacore
Albacore.configure do |config|
    config.log_level = (TEAMCITY ? :verbose : :normal)

    config.msbuild.solution = SOLUTION_FILE
    config.msbuild.properties = { :configuration => CONFIG }
    config.msbuild.use :net4
    config.msbuild.targets = [ :Clean, :Build ]
    config.msbuild.verbosity = "normal"

    config.xbuild.solution = SOLUTION_FILE
    config.xbuild.properties = { :configuration => CONFIG, :vstoolspath => (RUBY_PLATFORM.downcase.include?('darwin') ? '/Library/Frameworks/Mono.framework/Libraries' : '/usr/lib') + '/mono/xbuild/Microsoft/VisualStudio/v9.0' }
    config.xbuild.targets = [ :Build ] #:Clean upsets xbuild
    config.xbuild.verbosity = "normal"

    config.mspec.command = (MONO ? 'mono' : XUNIT_COMMAND)
    config.mspec.assemblies = FileList.new("#{SPECS_PATH}/**/*#{SPEC_ASSEMBLY_PATTERN}.dll").exclude(/obj\//).collect! { |element| ((MONO ? "#{MSPEC_COMMAND} " : '') + element) }

    CLEAN.include(FileList["#{SOURCE_PATH}/**/obj"])
    CLEAN.include(NUGET_PATH)
	CLOBBER.include(FileList["#{SOURCE_PATH}/**/bin"])
	CLOBBER.include(BUILD_PATH)
	CLOBBER.include(RESULTS_PATH)
end

# Tasks
task :default => [:test]

desc "Build"
task :build => [:init, :assemblyinfo] do
	if MONO
		Rake::Task[:xbuild].invoke
	else
		Rake::Task[:msbuild].invoke
	end
end

desc "Build + Tests (default)"
task :test => [:build] do
	Rake::Task[:runtests].invoke(TEST_ASSEMBLY_PATTERN_PREFIX)
end

desc "Build + Unit tests"
task :quick => [:build] do
	Rake::Task[:runtests].invoke(TEST_ASSEMBLY_PATTERN_UNIT)
end

desc "Build + Tests + Specs"
task :full => [:test] #[:test, :mspec]

desc "Build + Tests + Specs + Publish (local)"
task :publocal => [:full] do
	raise "Environment variable \"APIURL_LOCAL\" must be a valid nuget server url." unless !NUGET_APIURL_LOCAL.nil?
	raise "Environment variable \"APIKEY_LOCAL\" must be that of your nuget api key." unless !NUGET_APIKEY_LOCAL.nil?

	PublishNugets BUILD_NUMBER, NUGET_APIURL_LOCAL, NUGET_APIKEY_LOCAL
end

desc "Build + Tests + Specs + Publish (remote)"
task :publish => [:full] do
	raise "Environment variable \"APIURL_REMOTE\" must be a valid nuget server url." unless !NUGET_APIURL_REMOTE.nil?
	raise "Environment variable \"APIKEY_REMOTE\" must be that of your nuget api key." unless !NUGET_APIKEY_REMOTE.nil?

	if not TEAMCITY
		puts "\n\nThis will publish your local build to the remote nuget feed. Are you sure (y/n)?"
		response = $stdin.gets.chomp

		raise "Publish aborted." unless response.downcase.eql?("y")
	end

	PublishNugets BUILD_NUMBER, NUGET_APIURL_REMOTE, NUGET_APIKEY_REMOTE
end

# Hidden tasks
task :init => [:clobber] do
	Dir.mkdir BUILD_PATH unless File.exists?(BUILD_PATH)
	Dir.mkdir RESULTS_PATH unless File.exists?(RESULTS_PATH)
	Dir.mkdir ARTIFACTS_PATH unless File.exists?(ARTIFACTS_PATH)
end

task :ci => [:full]

msbuild :msbuild

xbuild :xbuild

assemblyinfo :assemblyinfo do |asm|
	asm_version = BUILD_NUMBER

	begin
		commit = `git log -1 --pretty=format:%H`
	rescue
		commit = "git unavailable"
	end

	asm.language = "C#"
	asm.version = BUILD_NUMBER
	asm.file_version = BUILD_NUMBER
	asm.company_name = SOLUTION_COMPANY
	asm.product_name = SOLUTION_NAME
	asm.copyright = SOLUTION_COPYRIGHT
	asm.custom_attributes :AssemblyConfiguration => CONFIG, :AssemblyInformationalVersion => asm_version
	asm.output_file = ASSEMBLY_INFO
	asm.com_visible = false
end

task :runtests, [:boundary] do |t, args|
	args.with_default(:boundary => "*")
	
	runner = XUnitTestRunnerCustom.new(MONO ? 'mono' : XUNIT_COMMAND)
	runner.html_output = RESULTS_PATH

	assemblies = Array.new

	args["boundary"].split(/,/).each do |this_boundary|
		FileList.new("#{TESTS_PATH}/*#{this_boundary}")
				.collect! { |element| 
					FileList.new("#{element}/**/*#{this_boundary}.dll")
						.exclude(/obj\//)
						.each do |this_file|
							assemblies.push (MONO ? "#{XUNIT_COMMAND} " : '') + this_file
						end
				}

		runner.assemblies = assemblies
		runner.execute
	end
end

mspec :mspec

# XUnitTestRunner needs some Mono help
class XUnitTestRunnerCustom < XUnitTestRunner
    def build_html_output
	    fail_with_message 'Directory is required for html_output' if !File.directory?(File.expand_path(@html_output))
	    "/nunit \"@#{File.join(File.expand_path(@html_output),"%s.html")}\""
	end
end

# Helper methods
def PublishNugets(version, apiurl, apikey)
	PackageNugets(version)

	nupkgs = FileList["#{NUGET_PATH}/*#{$version}.nupkg"]
    nupkgs.each do |nupkg| 
        puts "Pushing #{Pathname.new(nupkg).basename}"
        nuget_push = NuGetPush.new
        nuget_push.source = "\"" + apiurl + "\""
		nuget_push.apikey = apikey
        nuget_push.command = (MONO ? 'mono ' : '') + NUGET_COMMAND
        nuget_push.package = (MONO ? nupkg : nupkg.gsub('/','\\'))
        nuget_push.create_only = false
        nuget_push.execute
    end
end

def PackageNugets(nuspec_version)
	raise "Invalid nuspec version specified." unless !nuspec_version.nil?

	Dir.mkdir NUGET_PATH unless File.exists?(NUGET_PATH)

    FileUtils.cp_r FileList["#{NUSPEC_PATH}/**/*.nuspec"], "#{NUGET_PATH}"

    nuspecs = FileList["#{NUGET_PATH}/**/*.nuspec"]

	UpdateNuSpecVersions nuspecs, nuspec_version

    nuspecs.each do |nuspec|      
        nuget = NuGetPack.new
        nuget.command = NUGET_COMMAND
        nuget.nuspec = "\"#{nuspec}\""
        nuget.output = NUGET_PATH
        nuget.parameters = "-BasePath \"#{NUSPEC_PATH}\""
        nuget.execute
    end
end

def UpdateNuSpecVersions(nuspecs, nuspec_version)
	raise "No nuspecs to update." unless !nuspecs.nil?
	raise "Invalid nuspec version specified." unless !nuspec_version.nil?

    nuspecs.each do |nuspec|
        puts "Updating #{Pathname.new(nuspec).basename}"
        update_xml nuspec do |xml|
            xml.root.elements["metadata/version"].text = nuspec_version
            local_dependencies = xml.root.elements["metadata/dependencies/dependency[contains(@id,'#{SOLUTION_NAME}')]"]
            local_dependencies.attributes["version"] = "[#{nuspec_version}]" unless local_dependencies.nil?
            xml.root.elements["metadata/authors"].text = SOLUTION_COMPANY
            xml.root.elements["metadata/summary"].text = SOLUTION_DESC
            xml.root.elements["metadata/licenseUrl"].text = SOLUTION_LICENSE
            xml.root.elements["metadata/projectUrl"].text = SOLUTION_URL
        end
    end
end

def update_xml(xml_path)
    xml_file = File.new(xml_path)
    xml = REXML::Document.new xml_file
 
    yield xml
 
    xml_file.close
         
    xml_file = File.open(xml_path, "w")
    formatter = REXML::Formatters::Default.new(5)
    formatter.write(xml, xml_file)
    xml_file.close 
end