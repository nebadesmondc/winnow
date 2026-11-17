# Package manager and tool caches.

@(

    @{
        Id       = 'cache.uv'
        Title    = 'uv package cache'
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
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
    }

    # _cacache only; _npx has its own rule.
    @{
        Id       = 'cache.npm'
        Title    = 'npm package cache'
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
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
    }

    @{
        Id       = 'cache.pnpm'
        Title    = 'pnpm content-addressable store'
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
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
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
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
    }

    # Gradle caches and daemon only; never init.d, gradle.properties or wrapper.
    @{
        Id       = 'cache.gradle.caches'
        Title    = 'Gradle dependency cache'
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'GRADLE_USER_HOME'; Sub = 'caches' }
            @{ Type = 'Path'; Base = 'USERPROFILE'; Sub = '.gradle\caches' }
        )
        MinBytes    = 100MB
        Consequence = 'The next Gradle build re-downloads dependencies and re-runs its build cache. Slower first build, nothing lost.'
        Docs        = 'https://docs.gradle.org/current/userguide/dependency_caching.html'
    }

    @{
        Id       = 'cache.gradle.daemon'
        Title    = 'Gradle daemon logs'
        Category = 'AppCache'
        Tier     = 'Transient'
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
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
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
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'PLAYWRIGHT_BROWSERS_PATH' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'ms-playwright' }
        )
        MinBytes    = 100MB
        MinAgeDays  = 30
        Consequence = 'Browser engines must be reinstalled with `npx playwright install` before the next browser test run.'
        Docs        = 'https://playwright.dev/docs/browsers'
    }

    @{
        Id       = 'cache.pub'
        Title    = 'Dart/Flutter pub cache'
        Category = 'PackageCache'
        Tier     = 'Rebuildable'
        Resolve  = @(
            @{ Type = 'Env'; Name = 'PUB_CACHE' }
            @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'Pub\Cache' }
        )
        MinBytes    = 100MB
        MinAgeDays  = 14
        Consequence = 'The next `pub get` or `flutter pub get` re-downloads packages.'
        Docs        = 'https://dart.dev/tools/pub/environment-variables'
    }

    @{
        Id       = 'temp.user'
        Title    = 'User temporary files'
        Category = 'AppCache'
        Tier     = 'Transient'
        Resolve  = @(
            @{ Type = 'Path'; Base = 'TEMP' }
        )
        Target      = 'Children'
        MinBytes    = 5MB
        MinAgeDays  = 2
        Consequence = 'Discards leftover temporary directories older than two days. Anything an application is still using is skipped.'
    }

)
