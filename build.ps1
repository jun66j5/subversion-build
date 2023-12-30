$svnarcurl = $Env:SVNARC
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
$java_home = $Env:JAVA_HOME
$junit_file = "$workspace\arc\junit-$junit_ver.jar"
$python = $pythonLocation ? "$pythonLocation\python.exe" : 'python.exe'

if ($svnarcurl) {
    $svnarcurl = $svnarcurl -Replace '\.tar\.[a-z0-9]+$', '.zip'
    $svnarcdir = "$workspace\arc"
    $svnarcfile = ([uri]$svnarcurl).Segments[-1]
    $svnarcfile = "$svnarcdir\$svnarcfile"
    Expand-Archive -LiteralPath $svnarcfile -DestinationPath $workspace
    Rename-Item "$workspace\subversion-*.*.*" "$workspace\subversion"
}
Push-Location -LiteralPath "$workspace\subversion"

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
        # apr-util
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
        # httpd
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
        # serf
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
        if ($input_targets -Contains 'swig-py') {
            $genmake_opts += "--with-py3c=$workspace\py3c"
            $build_targets += '__SWIG_PYTHON__'
            $test_targets += '--swig=python'
        }
        if ($input_targets -Contains 'swig-pl') {
            $build_targets += '__SWIG_PERL__'
            $test_targets += '--swig=perl'
        }
        if ($input_targets -Contains 'javahl') {
            $genmake_opts += @("--with-jdk=$java_home",
                               "--with-junit=$junit_file")
            $build_targets += @('__JAVAHL__', '__JAVAHL_TESTS__')
            $test_targets += '--javahl'
        }
        $build_targets = $build_targets -Join ';'
    }
}

if (!$svnarcurl) {
    New-Item -Force -ItemType Directory -Path "subversion\bindings\swig\proxy"
    & svn diff -c1908545 https://svn.apache.org/repos/asf/subversion/trunk/ | & git apply -p0 -R -
}
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
$Env:PATH = "$deps_prefix\bin;$vcpkg_dir\bin;$($Env:PATH)"
$rc = 0
foreach ($item in $test_targets) {
    & $python win-tests.py -crv "--httpd-dir=$deps_prefix" --httpd-no-log $item
    if ($LASTEXITCODE) {
        Write-Warning "win-tests.py $item exited with $LASTEXITCODE"
        $rc = 1
    }
}
exit $rc
