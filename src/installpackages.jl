include("DeclarativePackages.jl")
using DeclarativePackages

if !haskey(ENV, "DECLARE_VERBOSITY")
    ENV["DECLARE_VERBOSITY"] = 1
end

function installpackages()
    lines = readfile()
    init(lines)
    lines = update_base_package(lines)
    packages = parselines(lines)
    needbuilding = install(packages)
    resolve(packages, needbuilding)
    finish()
end

function update_base_package(lines)
    if haskey(ENV, "JULIA_PKG_NAME") && haskey(ENV, "JULIA_PKG_COMMIT") && !isempty(ENV["JULIA_PKG_NAME"]) && !isempty(ENV["JULIA_PKG_COMMIT"])
        commit = ENV["JULIA_PKG_COMMIT"]
        pkg_base_name = basename(ENV["JULIA_PKG_NAME"])

        # Assumes package has .jl in string
        pkg_idx = find(x->ismatch(Regex("$(pkg_base_name).jl", "i"), x), lines)

        log(1, "Found environment variables:")
        log(1, "  JULIA_PKG_NAME=$pkg_base_name")
        log(1, "  JULIA_PKG_COMMIT=$commit")

        if length(pkg_idx) == 1
            pkg_line = lines[pkg_idx]
            url = split(pkg_line[1])[1]
            lines[pkg_idx] = "$url $commit"
            log(1, "Setting $url to commit $commit")
        elseif length(pkg_idx) > 1
            throw(ArgumentError("Was not able to find unique julia package name [$pkg_base_name] in DECLARE file"))
        else
            throw(ArgumentError("DECLARE file is missing the julia package name [$pkg_base_name]"))
        end
    end
    return lines
end

function readfile()
    log(1, "Parsing $(ENV["DECLARE"]) ... ")
    lines = split(readstring(ENV["DECLARE"]), '\n')
    lines = map(x->replace(x, r"#.*", ""), lines)
    lines = filter(x->!isempty(x), lines)
    return lines
end

pkgpath(basepath, pkg) = normpath(basepath*"/v$(VERSION.major).$(VERSION.minor)/$pkg/")
markreadonly(path) = run(`chmod a-w $path`)
stepout(path, n=1) = normpath(path*"/"*repeat("../",n))

function hardlinkdirs(existingpath, path)
    log(3, "hardlinking: existingpath: $existingpath\npath: $path")
    assert(existingpath[end]=='/')
    assert(path[end]=='/')
    mkpath(path)
    readdirabs(path) = map(x->(x, path*x), readdir(path))
    items = readdirabs(existingpath)
    for dir in filter(x->isdir(x[2]), items)
        hardlinkdirs(dir[2]*"/", path*dir[1]*"/")
    end
    for file in filter(x->!isdir(x[2]), items)
        is_apple() && ccall((:link, "libc"), Int, (Ptr{UInt8}, Ptr{UInt8}), file[2] , path*file[1])
        is_linux() && ccall((:link, "libc.so.6"), Int, (Ptr{UInt8}, Ptr{UInt8}), file[2] , path*file[1])
    end
end


gitcmd(path, cmd) = `git --git-dir=$path.git --work-tree=$path $(split(cmd))`
function gitcommitof(path)
    log(2, "gitcommitof $path")
    cmd = gitcmd(path, "log -n 1 --format=%H")
    log(2, "gitcommitof cmd $cmd")
    r = strip(readstring(cmd))
    log(2, "gitcommitof result $r")
    r
end

function gitclone(name, url, path, commit="")
    log(2, "gitclone: name: $name url: $url path: $path commit: $commit")
    run(`git clone $url $path`)
    if isempty(commit)
        commit = gitcommitof(path)
    else
        # check if the repo knows this commit. if not, check in METADATA
        isknown = ismatch(Regex(commit), readstring(gitcmd(path, "tag")))
        if !isknown
            filename = Pkg.dir("METADATA/$name/versions/$(commit[2:end])/sha1")
            if exists(filename)
                commit = strip(readstring(filename))
            else
                # check if this is a known branch name
                isbranch = ismatch(Regex(commit), readstring(gitcmd(path, "branch -a")))
                if isbranch
                    commit = strip(readstring(gitcmd(path, "rev-parse origin/$commit")))
                elseif commit[1] == 'v'
                    error("gitclone: Could not find a commit hash for version $commit for package $name ($url)")
                end
            end
        end
    end

    run(gitcmd(path, "checkout --force -b pinned.$commit.tmp $commit"))
end


function existscheckout(pkg, commit)
    basepath = stepout(Pkg.dir(), 2)
    dirs = readdir(basepath)
    nontmp = filter(x->length(x)>3 && x[1:4]!="tmp_", dirs)
    for dir in nontmp
        path = pkgpath(basepath*dir, pkg)
        if exists(path) &&  gitcommitof(path) == commit
            log(2, "existscheckout: found $path for $pkg@$commit")
            return path
        end
    end
    return ""
end

function init(lines)
    metadata = filter(x->ismatch(r"METADATA.jl", x), lines)
    commit = ""
    if length(metadata)>0
        assert(length(metadata)==1)
        m = split(metadata[1])
        url = split(metadata[1])[1]
        length(m) > 1 ? commit = m[2] : ""
        log(2, "Found URL $url$(isempty(commit) ? "" : "@$commit") for METADATA")
    else
        url = "https://github.com/JuliaLang/METADATA.jl.git"
    end
    path = Pkg.dir("METADATA/")
    installorlink("METADATA", url, path, commit)
    #markreadonly(Pkg.dir("METADATA"))
end


parselines(lines) = filter(x->isa(x,Package), map(parseline, lines))
function parseline(a)
    parts = split(strip(a))

    if parts[1][1] == '@'
        os = parts[1]
        shift!(parts)
    else
        os = ""
    end

    nameorurl = parts[1]
    if contains(nameorurl, "/")
        url = nameorurl
        name = replace(replace(split(url, "/")[end], ".git", ""), ".jl", "")
        if ismatch(r"bitbucket", url)
            # Workaround: As of 2017-07-13, bitbucket have started enforcing
            # lower case URLs, even for repositories containing julia packages
            # with upper case names.
            url = lowercase(url)
        end
        isregistered = false
    else
        name = nameorurl
        url = strip(readstring("$(Pkg.dir())/METADATA/$name/url"))
        isregistered = true
    end
    if name=="METADATA"
        return []
    end

    commit = length(parts)>1 ? parts[2] : (isregistered ? "METADATA" : "")
    if length(split(commit,"."))==3
        commit = "v"*commit
    end
    return Package(os, name, url, commit, isregistered)
end


type Package
    os
    name
    url
    commit
    isregistered
end

function install(packages::Array)
    osx = filter(x->x.os=="@osx", packages)
    unix = filter(x->x.os=="@unix", packages)
    linux = filter(x->x.os=="@linux", packages)
    windows = filter(x->x.os=="@windows", packages)
    everywhere = filter(x->x.os=="", packages)
    is_apple() && map(install, osx)
    is_unix() && map(install, unix)
    is_linux() && map(install, linux)
    is_windows() && map(install, windows)
    needbuilding = filter(x->x!=nothing, map(install, everywhere))
end

function installorlink(name, url, path, commit)
    log(2, "Installorlink: $name $url $commit $path")
    existingpath = existscheckout(name, commit)
    if isempty(existingpath)
        gitclone(name, url, path, commit)
        return name
    else
        log(1, "Linking $(name) ...")
        hardlinkdirs(existingpath, path)
        return
    end
end

function install(a::Package)
    path = Pkg.dir(a.name*"/")

    version(a) = VersionNumber(map(x->parse(Int,x), split(a, "."))...)
    function latest()
        versionsdir = Pkg.dir("METADATA/$(a.name)/versions/")
        if exists(versionsdir)
            "v"*string(maximum(map(version, readdir(versionsdir))))
        else
            ""
        end
    end
    metadatacommit(version) = strip(readstring(Pkg.dir("METADATA/$(a.name)/versions/$(version[2:end])/sha1")))
    commit = a.commit == "METADATA" ? latest() : a.commit
    installorlink(a.name, a.url, path, commit)
end

function resolve(packages, needbuilding)
    open(Pkg.dir()*"/REQUIRE","w") do io
        for pkg in packages
            if !isempty(pkg.commit) && pkg.commit[1]=='v'
                m,n,o = map(x->parse(Int,x), split(pkg.commit[2:end], '.'))
                versions = "$m.$n.$o $m.$n.$(o+1)-"
            else
                versions = ""
            end
            log(3, "writing REQUIRE: $(pkg.os) $(pkg.name) $versions\n")
            write(io, "$(pkg.os) $(pkg.name) $versions\n")

            # add test dependencies
            if haskey(ENV, "DECLARE_INCLUDETEST") && ENV["DECLARE_INCLUDETEST"]=="true"
                testrequire = Pkg.dir(pkg.name*"/test/REQUIRE")
                if exists(testrequire)
                    write(io, readstring(testrequire))
                end
            end
        end
    end
    log(1, "Invoking Pkg.resolve() ...")
    Pkg.resolve()
    map(x -> Pkg.build(x), needbuilding)
end

function finish()
    exportDECLARE(ENV["DECLARE"])
end

installpackages()
