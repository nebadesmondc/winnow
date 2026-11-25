# Package manager and tool caches.

@(

    @{
        Id       = 'cache.uv'
        Title    = 'uv package cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'uv'; Args = 'cache dir'; TimeoutSec = 10 }
            @{ Type = 'Env'; Name = 'UV_CACHE_DIR' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'uv\cache' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'uv'; Args = 'cache clean' }
            @{ Type = 'Delete' }
        )
        MinBytes    = 50MB
        Consequence = 'The next uv install re-downloads wheels. Network cost only; no Python installs, tools or credentials are affected.'
        Docs        = 'https://docs.astral.sh/uv/concepts/cache/'
        Move        = @{
            Id = 'uv'; Title = 'uv cache'; Env = 'UV_CACHE_DIR'
            Verify = @{ Command = 'uv'; Args = 'cache dir' }
            Note = 'uv cannot hard-link across drives, so it copies packages into environments and warns once per install; UV_LINK_MODE=copy silences the warning.'
        }
    }

    # _cacache only; _npx has its own rule.
    @{
        Id       = 'cache.npm'
        Title    = 'npm package cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'npm'; Args = 'config get cache'; TimeoutSec = 20; Sub = '_cacache' }
            @{ Type = 'Env'; Name = 'NPM_CONFIG_CACHE'; Sub = '_cacache' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'npm-cache\_cacache' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'npm'; Args = 'cache clean --force' }
            @{ Type = 'Delete' }
        )
        MinBytes    = 50MB
        Consequence = 'The next npm install re-downloads packages. Globally installed CLIs live elsewhere and are untouched.'
        Docs        = 'https://docs.npmjs.com/cli/commands/npm-cache'
        # The whole npm-cache folder moves, with _npx and logs.
        Move        = @{
            Id = 'npm'; Title = 'npm cache'; Env = 'NPM_CONFIG_CACHE'; Up = 1
            Verify = @{ Command = 'npm'; Args = 'config get cache' }
        }
    }

    @{
        Id       = 'cache.pnpm'
        Title    = 'pnpm content-addressable store'
        Verdict  = 'Clean'
        # The store, not pnpm-cache (metadata).
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'pnpm'; Args = 'store path'; TimeoutSec = 20 }
            @{ Type = 'Env'; Name = 'PNPM_HOME'; Sub = 'store' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'pnpm\store' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'pnpm'; Args = 'store prune' }
            @{ Type = 'Delete' }
        )
        MinBytes    = 50MB
        Consequence = 'Projects using pnpm re-link or re-download on their next install.'
        Docs        = 'https://pnpm.io/cli/store'
    }

    @{
        Id       = 'cache.pip'
        Title    = 'pip wheel cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'pip'; Args = 'cache dir'; TimeoutSec = 20 }
            @{ Type = 'Env'; Name = 'PIP_CACHE_DIR' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'pip\cache' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'pip'; Args = 'cache purge' }
            @{ Type = 'Delete' }
        )
        MinBytes    = 25MB
        Consequence = 'The next pip install rebuilds or re-downloads wheels. Installed packages and virtual environments are untouched.'
        Docs        = 'https://pip.pypa.io/en/stable/cli/pip_cache/'
        Move        = @{
            Id = 'pip'; Title = 'pip cache'; Env = 'PIP_CACHE_DIR'
            Verify = @{ Command = 'pip'; Args = 'cache dir' }
        }
    }

    # Gradle caches and daemon only; never init.d, gradle.properties or wrapper.
    @{
        Id       = 'cache.gradle.caches'
        Title    = 'Gradle dependency cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'GRADLE_USER_HOME'; Sub = 'caches' }
            @{ Type = 'Path'; Base = 'USERPROFILE'; Sub = '.gradle\caches' }
        )
        MinBytes    = 100MB
        Consequence = 'The next Gradle build re-downloads dependencies and re-runs its build cache. Slower first build, nothing lost.'
        Docs        = 'https://docs.gradle.org/current/userguide/dependency_caching.html'
        # The whole Gradle home moves, so gradle.properties and init scripts come along.
        Move        = @{
            Id = 'gradle'; Title = 'Gradle home'; Env = 'GRADLE_USER_HOME'; Up = 1
            RequiresClosed = @('java')
            Note = 'An IDE with its own Gradle user home setting keeps using that folder.'
        }
    }

    @{
        Id       = 'cache.gradle.daemon'
        Title    = 'Gradle daemon logs'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'GRADLE_USER_HOME'; Sub = 'daemon' }
            @{ Type = 'Path'; Base = 'USERPROFILE'; Sub = '.gradle\daemon' }
        )
        MinBytes       = 25MB
        RequiresClosed = @('java')
        Consequence    = 'Removes Gradle daemon logs and registries. Running daemons are detected and the removal is skipped if one is live.'
    }

    @{
        Id       = 'cache.npx'
        Title    = 'npx one-off package cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'npm'; Args = 'config get cache'; TimeoutSec = 20; Sub = '_npx' }
            @{ Type = 'Env'; Name = 'NPM_CONFIG_CACHE'; Sub = '_npx' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'npm-cache\_npx' }
        )
        MinBytes    = 25MB
        Consequence = 'Packages run once via npx are re-fetched next time they are invoked.'
    }

    @{
        Id       = 'cache.playwright'
        Title    = 'Playwright browser binaries'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'PLAYWRIGHT_BROWSERS_PATH' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'ms-playwright' }
        )
        MinBytes    = 100MB
        MinAgeDays  = 30
        Consequence = 'Browser engines must be reinstalled with `npx playwright install` before the next browser test run.'
        Docs        = 'https://playwright.dev/docs/browsers'
        Move        = @{ Id = 'playwright'; Title = 'Playwright browsers'; Env = 'PLAYWRIGHT_BROWSERS_PATH' }
    }

    @{
        Id       = 'cache.pub'
        Title    = 'Dart/Flutter pub cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'PUB_CACHE' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'Pub\Cache' }
        )
        MinBytes    = 100MB
        MinAgeDays  = 14
        Consequence = 'The next `pub get` or `flutter pub get` re-downloads packages.'
        Docs        = 'https://dart.dev/tools/pub/environment-variables'
        # Tools from `dart pub global activate` run from bin, which is on PATH.
        Move        = @{ Id = 'pub'; Title = 'Dart/Flutter pub cache'; Env = 'PUB_CACHE'; PathFolder = 'bin' }
    }

    @{
        Id       = 'cache.nuget'
        Title    = 'NuGet global packages'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'dotnet'; Args = 'nuget locals global-packages --list'; TimeoutSec = 30 }
            @{ Type = 'Env'; Name = 'NUGET_PACKAGES' }
            @{ Type = 'Path'; Base = 'USERPROFILE'; Sub = '.nuget\packages' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'dotnet'; Args = 'nuget locals global-packages --clear' }
            @{ Type = 'Delete' }
        )
        MinBytes       = 100MB
        RequiresClosed = @('devenv')
        Consequence    = 'The next restore re-downloads every package a .NET project uses. Projects and installed SDKs are untouched.'
        Docs           = 'https://learn.microsoft.com/nuget/consume-packages/managing-the-global-packages-and-cache-folders'
        Move           = @{
            Id = 'nuget'; Title = 'NuGet packages'; Env = 'NUGET_PACKAGES'
            Verify = @{ Command = 'dotnet'; Args = 'nuget locals global-packages --list' }
            RequiresClosed = @('devenv', 'MSBuild', 'VBCSCompiler')
        }
    }

    @{
        Id       = 'cache.go.mod'
        Title    = 'Go module cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'go'; Args = 'env GOMODCACHE'; TimeoutSec = 20 }
            @{ Type = 'Env'; Name = 'GOMODCACHE' }
            @{ Type = 'Path'; Base = 'USERPROFILE'; Sub = 'go\pkg\mod' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'go'; Args = 'clean -modcache' }
            @{ Type = 'Delete' }
        )
        MinBytes    = 100MB
        Consequence = 'The next go build or go mod download re-downloads modules. Programs installed with go install are untouched.'
        Docs        = 'https://go.dev/ref/mod#module-cache'
        Move        = @{
            Id = 'go-mod'; Title = 'Go module cache'; Env = 'GOMODCACHE'
            Verify = @{ Command = 'go'; Args = 'env GOMODCACHE' }
        }
    }

    @{
        Id       = 'cache.go.build'
        Title    = 'Go build cache'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Cli'; Command = 'go'; Args = 'env GOCACHE'; TimeoutSec = 20 }
            @{ Type = 'Env'; Name = 'GOCACHE' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'go-build' }
        )
        Reclaim  = @(
            @{ Type = 'VendorCli'; Command = 'go'; Args = 'clean -cache' }
            @{ Type = 'Delete' }
        )
        MinBytes    = 100MB
        Consequence = 'The next go build compiles everything again: slower once, nothing lost.'
        Docs        = 'https://pkg.go.dev/cmd/go#hdr-Build_and_test_caching'
        Move        = @{
            Id = 'go-build'; Title = 'Go build cache'; Env = 'GOCACHE'
            Verify = @{ Command = 'go'; Args = 'env GOCACHE' }
        }
    }

    @{
        Id       = 'temp.user'
        Title    = 'User temporary files'
        Verdict  = 'Clean'
        Resolve  = @(
            @{ Type = 'Path'; Base = 'TEMP' }
        )
        Target      = 'Children'
        MinBytes    = 5MB
        MinAgeDays  = 2
        Consequence = 'Discards leftover temporary directories older than two days. Anything an application is still using is skipped.'
    }

)
