$svnarcurl = $Env:SVNARC
$swig_ver = $Env:SWIG_VER
$junit_ver = $Env:JUNIT_VER
$LocalAppData = $Env:LocalAppData
$ProgramData = $Env:ProgramData
$workspace = $Env:GITHUB_WORKSPACE
$input_targets = $Env:INPUT_TARGETS -Split ' '
$arch = 'x64'
$pythonLocation = $Env:pythonLocation
$vcpkg_root = $Env:VCPKG_INSTALLATION_ROOT
$vcpkg_downloads = "$LocalAppData\vcpkg\downloads"
$vcpkg_triplet = "$arch-windows-release"
$vcpkg_dir = "$vcpkg_root\installed\$vcpkg_triplet"
$vcpkg_dir_static = "$vcpkg_root\installed\$arch-windows-static"
$deps_prefix = "$LocalAppData\deps"
$swig_arc = "$workspace\arc\swigwin-$swig_ver.zip"
$java_home = $Env:JAVA_HOME
$junit_file = "$workspace\arc\junit-$junit_ver.jar"
$python = $pythonLocation ? "$pythonLocation\python.exe" : 'python.exe'

$Env:PATH = "$vcpkg_root;$($Env:PATH)"

if ($svnarcurl) {
    $svnarcurl = $svnarcurl -Replace '\.tar\.[a-z0-9]+$', '.zip'
    $svnarcdir = "$workspace\arc"
    $svnarcfile = ([uri]$svnarcurl).Segments[-1]
    $svnarcfile = "$svnarcdir\$svnarcfile"
    Expand-Archive -LiteralPath $svnarcfile -DestinationPath $workspace
    Rename-Item "$workspace\subversion-*.*.*" "$workspace\subversion"
}
Push-Location -LiteralPath "$workspace\subversion"

Write-Output '::group::vcpkg'
New-Item -Force -ItemType Directory -Path $vcpkg_downloads
Push-Location -LiteralPath $vcpkg_root
& git fetch --depth=1 origin
& git checkout origin/master
Copy-Item -LiteralPath "triplets\$arch-windows.cmake" `
          -Destination "triplets\$vcpkg_triplet.cmake"
Add-Content -LiteralPath "triplets\$vcpkg_triplet.cmake" `
            -Value 'set(VCPKG_BUILD_TYPE release)'
Pop-Location
$vcpkg_opts = @("--downloads-root=$vcpkg_downloads",
                "--triplet=$vcpkg_triplet")
$vcpkg_targets = Get-Content -LiteralPath "$workspace\vcpkg.txt"
& vcpkg $vcpkg_opts update
& vcpkg $vcpkg_opts install $vcpkg_targets
if ($LASTEXITCODE) {
    Write-Error "vcpkg install exited with $LASTEXITCODE"
    exit 1
}
Write-Output '::endgroup::'

switch -Exact ($args[0]) {
    'prepare' {
        New-Item -Force -ItemType Directory -Path $deps_prefix
        $cmake_prefix = $deps_prefix.Replace('\', '/')
        $cmake_vcpkg_dir = $vcpkg_dir.Replace('\', '/')
        $cmake_build_flags = @(
            '--build', '.', '--config', 'Release', '--parallel',
            '--target', 'ALL_BUILD', '--target', 'INSTALL',
            '--',
            '-nologo', '-v:q', '-fl')
        # apr
        Write-Output '::group::apr'
        Push-Location "$workspace\deps\apr"
        & cmake -D "CMAKE_INSTALL_PREFIX=$cmake_prefix" `
                -D CMAKE_BUILD_TYPE=Release `
                -D MIN_WINDOWS_VER=0x0600 `
                -D APR_HAVE_IPV6=ON `
                -D APR_INSTALL_PRIVATE_H=ON `
                -D APR_BUILD_TESTAPR=OFF `
                -D INSTALL_PDB=OFF `
                .
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        & cmake $cmake_build_flags
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        Pop-Location
        Write-Output '::endgroup::'
        # apr-util
        Write-Output '::group::apr-util'
        Push-Location "$workspace\deps\apr-util"
        & cmake -D "CMAKE_INSTALL_PREFIX=$cmake_prefix" `
                -D "OPENSSL_ROOT_DIR=$cmake_vcpkg_dir" `
                -D "EXPAT_INCLUDE_DIR=$cmake_vcpkg_dir/include" `
                -D "EXPAT_LIBRARY=$cmake_vcpkg_dir/lib/libexpat.lib" `
                -D CMAKE_BUILD_TYPE=Release `
                -D APU_HAVE_CRYPTO=ON `
                -D APR_BUILD_TESTAPR=OFF `
                -D INSTALL_PDB=OFF `
                .
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        & cmake $cmake_build_flags
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        Copy-Item -Path "$vcpkg_dir\include\expat.h" -Destination "$deps_prefix\include"
        Copy-Item -Path "$vcpkg_dir\lib\libexpat.lib" -Destination "$deps_prefix\lib"
        Copy-Item -Path "$vcpkg_dir\bin\libexpat.dll" -Destination "$deps_prefix\bin"
        Pop-Location
        Write-Output '::endgroup::'
        # httpd
        Write-Output '::group::httpd'
        Push-Location "$workspace\deps\httpd"
        & cmake -D "CMAKE_INSTALL_PREFIX=$cmake_prefix" `
                -D "APR_INCLUDE_DIR=$cmake_prefix/include" `
                -D "APR_LIBRARIES=$cmake_prefix/lib/libapr-1.lib;$cmake_prefix/lib/libaprutil-1.lib" `
                -D "ZLIB_INCLUDE_DIR=$cmake_vcpkg_dir/include" `
                -D "ZLIB_LIBRARY=$cmake_vcpkg_dir/lib/zlib.lib" `
                -D "OPENSSL_ROOT_DIR=$cmake_vcpkg_dir" `
                -D "PCRE_INCLUDE_DIR=$cmake_vcpkg_dir/include" `
                -D "PCRE_LIBRARIES=$cmake_vcpkg_dir/lib/pcre.lib" `
                -D CMAKE_BUILD_TYPE=Release `
                -D ENABLE_MODULES=i `
                -D INSTALL_PDB=OFF `
                -D INSTALL_MANUAL=OFF `
                .
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        & cmake $cmake_build_flags
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        Copy-Item -Path "$vcpkg_dir\bin\libcrypto-*.dll" -Destination "$deps_prefix\bin"
        Copy-Item -Path "$vcpkg_dir\bin\libssl-*.dll" -Destination "$deps_prefix\bin"
        Copy-Item -Path "$vcpkg_dir\bin\pcre.dll" -Destination "$deps_prefix\bin"
        Copy-Item -Path "$vcpkg_dir\bin\zlib1.dll" -Destination "$deps_prefix\bin"
        Pop-Location
        Write-Output '::endgroup::'
        # serf
        Write-Output '::group::serf'
        Push-Location "$workspace\deps\serf"
        & $python -m pip install scons
        $scons = ($pythonLocation -eq $null) ? 'scons.exe' : "$pythonLocation\scripts\scons.exe"
        # for serf 1.3.x
        & "C:\Program Files\Git\usr\bin\sed.exe" `
            -i -e "s|'[$]APR/include/apr-1', '[$]APU/include/apr-1'|'`$APR/include', '`$APU/include'|g" `
            SConstruct
        & $scons SOURCE_LAYOUT=no `
                 APR_STATIC=no `
                 "TARGET_ARCH=$arch" `
                 "PREFIX=$deps_prefix" `
                 "LIBDIR=$deps_prefix\lib" `
                 "APR=$deps_prefix" `
                 "APU=$deps_prefix" `
                 "OPENSSL=$vcpkg_dir" `
                 "ZLIB=$vcpkg_dir"
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        & $scons install
        if ($LASTEXITCODE) {
            exit $LASTEXITCODE
        }
        Pop-Location
        Write-Output '::endgroup::'
        exit
    }
    'core' {
        $genmake_opts = @()
        $build_targets = '__ALL__;__MORE__'
        $test_targets = @('--parallel')
    }
    'bindings' {
        $genmake_opts = @()
        $build_targets = @('__ALL__')
        $test_targets = @()
        $use_swig = $false
        if ($input_targets -Contains 'swig-py') {
            $genmake_opts += "--with-py3c=$workspace\py3c"
            $build_targets += '__SWIG_PYTHON__'
            $test_targets += '--swig=python'
            $use_swig = $true
        }
        if ($input_targets -Contains 'swig-pl') {
            $build_targets += '__SWIG_PERL__'
            $test_targets += '--swig=perl'
            $use_swig = $true
        }
        if ($input_targets -Contains 'javahl') {
            $genmake_opts += @("--with-jdk=$java_home",
                               "--with-junit=$junit_file")
            $build_targets += @('__JAVAHL__', '__JAVAHL_TESTS__')
            $test_targets += '--javahl'
        }
        if ($use_swig) {
            Expand-Archive -LiteralPath $swig_arc -DestinationPath $workspace
            $genmake_opts += "--with-swig=$workspace\swigwin-$swig_ver"
        }
        $build_targets = $build_targets -Join ';'
    }
}

if (!$svnarcurl) {
    New-Item -Force -ItemType Directory -Path "subversion\bindings\swig\proxy"
    & svn diff -c1908545 https://svn.apache.org/repos/asf/subversion/trunk/ | & git apply -p0 -R -
}

$Env:PATH = "$deps_prefix\bin;$vcpkg_dir\bin;$vcpkg_dir\tools\gettext\bin;$($Env:PATH)"

Write-Output '::group::gen-make.py'
& $python gen-make.py `
          --vsnet-version=2019 `
          --enable-nls `
          "--with-apr=$deps_prefix" `
          "--with-apr-util=$deps_prefix" `
          "--with-httpd=$deps_prefix" `
          "--with-openssl=$vcpkg_dir" `
          "--with-zlib=$vcpkg_dir" `
          "--with-serf=$deps_prefix" `
          "--with-sqlite=$vcpkg_dir_static" `
          "--with-libintl=$vcpkg_dir" `
          $genmake_opts
if ($LASTEXITCODE) {
    exit $LASTEXITCODE
}
Write-Output '::endgroup::'

Write-Output '::group::msbuild subversion_vcnet.sln'
Set-Content -LiteralPath "Directory.Build.Props" -Value @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemDefinitionGroup>
    <ClCompile>
      <DisableSpecificWarnings>4459;4702;%(DisableSpecificWarnings)</DisableSpecificWarnings>
    </ClCompile>
  </ItemDefinitionGroup>
</Project>
'@
& msbuild subversion_vcnet.sln `
          -nologo -v:q -m -fl `
          "-t:$build_targets" "-p:Configuration=Release;Platform=$arch"
if ($LASTEXITCODE) {
    exit $LASTEXITCODE
}
Write-Output '::endgroup::'

Write-Output '::group::dist'
$dist_dir = "$LocalAppData\dist"
New-Item -Path "$dist_dir\bin" -ItemType Directory -Force
Copy-Item -Path @("$deps_prefix\bin\libapr*.dll",
                  "$deps_prefix\bin\apr_*.dll",
                  "$vcpkg_dir\bin\libexpat.dll",
                  "$vcpkg_dir\bin\iconv-*.dll",
                  "$vcpkg_dir\bin\intl-*.dll",
                  "$vcpkg_dir\bin\libcrypto-*.dll",
                  "$vcpkg_dir\bin\libssl-*.dll",
                  "$vcpkg_dir\bin\zlib1.dll",
                  "Release\subversion\libsvn_*\*.dll") `
          -Destination "$dist_dir\bin" `
          -Verbose
switch -Exact ($args[0]) {
    'core' {
        Copy-Item -Path "Release\subversion\svn*\*.exe" `
                  -Destination "$dist_dir\bin" `
                  -Verbose
        New-Item -Path "$dist_dir\share\locale" -ItemType Directory -Force
        Get-ChildItem "Release\mo" -Filter "*.mo" | ForEach-Object {
            $locale = $_.BaseName
            $locale_dir = "$dist_dir\share\locale\$locale\LC_MESSAGES"
            New-Item -Path $locale_dir -ItemType Directory -Verbose
            Copy-Item -Path $_.FullName -Destination "$locale_dir\subversion.mo" -Verbose
        }
    }
    'bindings' {
        if ($build_targets.Contains('__SWIG_PYTHON__')) {
            $dist_pydir = "$dist_dir\python\Lib\site-packages"
            New-Item -Path @("$dist_pydir\svn",
                             "$dist_pydir\libsvn") `
                     -ItemType Directory `
                     -Force
            Copy-Item -Path "subversion\bindings\swig\python\svn\*.py" `
                      -Destination "$dist_pydir\svn" `
                      -Verbose
            Copy-Item -Path @("subversion\bindings\swig\python\*.py",
                              "Release\subversion\bindings\swig\python\libsvn_swig_py\*.dll",
                              "Release\subversion\bindings\swig\python\_*.pyd") `
                      -Destination "$dist_pydir\libsvn" `
                      -Verbose
            & $python -m compileall $dist_pydir
        }
        if ($build_targets.Contains('__SWIG_PERL__')) {
            $dist_pldir = "$dist_dir\perl\site\lib"
            Copy-Item -Path "Release\subversion\bindings\swig\perl\libsvn_swig_perl\*.dll" `
                      -Destination "$dist_dir\bin" `
                      -Verbose
            New-Item -Path @("$dist_pldir\SVN", "$dist_pldir\auto\SVN") `
                     -ItemType Directory `
                     -Force
            Copy-Item -Path "subversion\bindings\swig\perl\native\*.pm" `
                      -Destination "$dist_pldir\SVN" `
                      -Verbose
            foreach ($name in @("_Client", "_Core", "_Delta", "_Fs", "_Ra",
                                "_Repos", "_Wc"))
            {
                $dir = "$dist_pldir\auto\SVN\$name"
                New-Item -Path $dir -ItemType Directory -Force
                Copy-Item -Path "Release\subversion\bindings\swig\perl\native\$name.dll" `
                          -Destination $dir `
                          -Verbose
            }
        }
        if ($build_targets.Contains('__SWIG_RUBY__')) {
            $dist_rbdir = "$dist_dir\ruby\lib"
            New-Item -Path @("$dist_rbdir\svn", "$dist_rbdir\svn\ext") `
                     -ItemType Directory `
                     -Force
            Copy-Item -Path "subversion\bindings\swig\ruby\svn\*.rb" `
                      -Destination "$dist_rbdir\svn" `
                      -Verbose
            Copy-Item -Path @("Release\subversion\bindings\swig\ruby\libsvn_swig_ruby\*.dll",
                              "Release\subversion\bindings\swig\ruby\*.so") `
                      -Destination "$dist_rbdir\svn\ext" `
                      -Verbose
        }
    }
}
Write-Output '::endgroup::'

$rc = 0
foreach ($item in $test_targets) {
    Write-Output "::group::win-tests.py $item"
    & $python win-tests.py -crv "--httpd-dir=$deps_prefix" --httpd-no-log $item
    if ($LASTEXITCODE) {
        Write-Warning "win-tests.py $item exited with $LASTEXITCODE"
        $rc = 1
    }
    Write-Output '::endgroup::'
}
exit $rc
