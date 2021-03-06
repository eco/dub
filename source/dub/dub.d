/**
	A package manager.

	Copyright: © 2012 Matthias Dondorff
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff, Sönke Ludwig
*/
module dub.dub;

import dub.compilers.compiler;
import dub.dependency;
import dub.installation;
import dub.utils;
import dub.registry;
import dub.package_;
import dub.packagemanager;
import dub.packagesupplier;
import dub.project;
import dub.generators.generator;

import vibecompat.core.file;
import vibecompat.core.log;
import vibecompat.data.json;
import vibecompat.inet.url;

// todo: cleanup imports.
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.string;
import std.typecons;
import std.zip;
import stdx.process;



/// The default supplier for packages, which is the registry
/// hosted by vibed.org.
PackageSupplier defaultPackageSupplier() {
	Url url = Url.parse("http://registry.vibed.org/");
	logDebug("Using the registry from %s", url);
	return new RegistryPS(url);
}

/// The Dub class helps in getting the applications
/// dependencies up and running. An instance manages one application.
class Dub {
	private {
		Path m_cwd, m_tempPath;
		Path m_root;
		PackageSupplier m_packageSupplier;
		Path m_userDubPath, m_systemDubPath;
		Json m_systemConfig, m_userConfig;
		PackageManager m_packageManager;
		Project m_project;
	}

	/// Initiales the package manager for the vibe application
	/// under root.
	this(PackageSupplier ps = defaultPackageSupplier())
	{
		m_cwd = Path(getcwd());

		version(Windows){
			m_systemDubPath = Path(environment.get("ProgramData")) ~ "dub/";
			m_userDubPath = Path(environment.get("APPDATA")) ~ "dub/";
			m_tempPath = Path(environment.get("TEMP"));
		} else version(Posix){
			m_systemDubPath = Path("/var/lib/dub/");
			m_userDubPath = Path(environment.get("HOME")) ~ ".dub/";
			m_tempPath = Path("/tmp");
		}
		
		m_userConfig = jsonFromFile(m_userDubPath ~ "settings.json", true);
		m_systemConfig = jsonFromFile(m_systemDubPath ~ "settings.json", true);

		m_packageSupplier = ps;
		m_packageManager = new PackageManager(m_systemDubPath ~ "packages/", m_userDubPath ~ "packages/");
	}

	/// Returns the name listed in the package.json of the current
	/// application.
	@property string projectName() const { return m_project.name; }

	@property Path projectPath() const { return m_root; }

	@property string[] configurations() const { return m_project.configurations; }

	@property inout(PackageManager) packageManager() inout { return m_packageManager; }

	@property Path binaryPath() const { return m_project.binaryPath; }

	void loadPackageFromCwd()
	{
		m_root = m_cwd;
		m_packageManager.projectPackagePath = m_root ~ ".dub/packages/";
		m_project = new Project(m_packageManager, m_root);
	}

	string getDefaultConfiguration(BuildPlatform platform) const { return m_project.getDefaultConfiguration(platform); }

	/// Lists all installed modules
	void list() {
		logInfo(m_project.info());
	}

	/// Performs installation and uninstallation as necessary for
	/// the application.
	/// @param options bit combination of UpdateOptions
	bool update(UpdateOptions options) {
		Action[] actions = m_project.determineActions(m_packageSupplier, options);
		if( actions.length == 0 ) return true;

		logInfo("The following changes could be performed:");
		bool conflictedOrFailed = false;
		foreach(Action a; actions) {
			logInfo("%s %s %s, %s", capitalize(to!string(a.type)), a.packageId, a.vers, a.location);
			if( a.type == Action.Type.conflict || a.type == Action.Type.failure ) {
				logInfo("Issued by: ");
				conflictedOrFailed = true;
				foreach(string pkg, d; a.issuer)
					logInfo(" "~pkg~": %s", d);
			}
		}

		if( conflictedOrFailed || options & UpdateOptions.JustAnnotate )
			return conflictedOrFailed;

		// Uninstall first

		// ??
		// foreach(Action a	   ; filter!((Action a)        => a.type == Action.Type.Uninstall)(actions))
			// uninstall(a.packageId);
		// foreach(Action a; filter!((Action a) => a.type == Action.Type.InstallUpdate)(actions))
			// install(a.packageId, a.vers);
		foreach(Action a; actions)
			if(a.type == Action.Type.uninstall){
				assert(a.pack !is null, "No package specified for uninstall.");
				uninstall(a.pack);
			}
		foreach(Action a; actions)
			if(a.type == Action.Type.install)
				install(a.packageId, a.vers, a.location);

		m_project.reinit();
		Action[] newActions = m_project.determineActions(m_packageSupplier, 0);
		if(newActions.length > 0) {
			logInfo("There are still some actions to perform:");
			foreach(Action a; newActions)
				logInfo("%s", a);
		}
		else
			logInfo("You are up to date");

		return newActions.length == 0;
	}

	/// Generate project files for a specified IDE.
	/// Any existing project files will be overridden.
	void generateProject(string ide, GeneratorSettings settings) {
		auto generator = createProjectGenerator(ide, m_project, m_packageManager);
		generator.generateProject(settings);
	}
	
	/// Creates a zip from the application.
	void createZip(string zipFile) {
		m_project.createZip(zipFile);
	}

	/// Prints some information to the log.
	void info() {
		logInfo("Status for %s", m_root);
		logInfo("\n" ~ m_project.info());
	}

	/// Gets all installed packages as a "packageId" = "version" associative array
	string[string] installedPackages() const { return m_project.installedPackagesIDs(); }

	/// Installs the package matching the dependency into the application.
	/// @param addToApplication if true, this will also add an entry in the
	/// list of dependencies in the application's package.json
	void install(string packageId, const Dependency dep, InstallLocation location = InstallLocation.projectLocal, bool addToApplication = false)
	{
		auto pinfo = m_packageSupplier.packageJson(packageId, dep);
		string ver = pinfo["version"].get!string;

		// Perform addToApplication
		if(addToApplication && !m_project.tryAddDependency(packageId, dep)) {
			logError("Installation of '%s' failed.", packageId);
			return;
		}

		if( m_packageManager.hasPackage(packageId, ver, location) ){
			logInfo("Package %s %s (%s) is already installed with the latest version, skipping upgrade.",
				packageId, ver, location);
			return;
		}

		logInfo("Downloading %s %s...", packageId, ver);

		logDebug("Acquiring package zip file");
		auto dload = m_root ~ ".dub/temp/downloads";
		auto tempfname = packageId ~ "-" ~ (ver.startsWith('~') ? ver[1 .. $] : ver) ~ ".zip";
		auto tempFile = m_tempPath ~ tempfname;
		string sTempFile = tempFile.toNativeString();
		if(exists(sTempFile)) remove(sTempFile);
		m_packageSupplier.storePackage(tempFile, packageId, dep); // Q: continue on fail?
		scope(exit) remove(sTempFile);

		logInfo("Installing %s %s...", packageId, ver);
		m_packageManager.install(tempFile, pinfo, location);
	}

	/// Uninstalls a given package from the list of installed modules.
	/// @removeFromApplication: if true, this will also remove an entry in the
	/// list of dependencies in the application's package.json
	void uninstall(in Package pack)
	{
		logInfo("Uninstalling %s in %s", pack.name, pack.path.toNativeString());

		m_packageManager.uninstall(pack);
	}

	void addLocalPackage(string path, string ver, bool system)
	{
		auto abs_path = Path(path);
		if( !abs_path.absolute ) abs_path = m_cwd ~ abs_path;
		m_packageManager.addLocalPackage(abs_path, Version(ver), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void removeLocalPackage(string path, bool system)
	{
		auto abs_path = Path(path);
		if( !abs_path.absolute ) abs_path = m_cwd ~ abs_path;
		m_packageManager.removeLocalPackage(abs_path, system ? LocalPackageType.system : LocalPackageType.user);
	}

	void createEmptyPackage(Path path)
	{
		if( !path.absolute() ) path = m_cwd ~ path;
		path.normalize();

		//Check to see if a target directory needs to be created
		if( !path.empty ){
			if( !existsFile(path) )
				createDirectory(path);
		} 

		//Make sure we do not overwrite anything accidentally
		if( existsFile(path ~ PackageJsonFilename) ||
			existsFile(path ~ "source") ||
			existsFile(path ~ "views") ||
			existsFile(path ~ "public") )
		{
			throw new Exception("The current directory is not empty.\n");
		}

		//raw strings must be unindented. 
		immutable packageJson = 
`{
	"name": "`~(path.empty ? "my-project" : path.head.toString())~`",
	"description": "An example project skeleton",
	"homepage": "http://example.org",
	"copyright": "Copyright © 2000, Your Name",
	"authors": [
		"Your Name"
	],
	"dependencies": {
	}
}
`;
		immutable appFile =
`import std.stdio;

void main()
{ 
	writeln("Edit source/app.d to start your project.");
}
`;

		//Create the common directories.
		createDirectory(path ~ "source");
		createDirectory(path ~ "views");
		createDirectory(path ~ "public");

		//Create the common files. 
		openFile(path ~ PackageJsonFilename, FileMode.Append).write(packageJson);
		openFile(path ~ "source/app.d", FileMode.Append).write(appFile);     

		//Act smug to the user. 
		logInfo("Successfully created an empty project in '"~path.toNativeString()~"'.");
	}
}
