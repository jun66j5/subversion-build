#! /bin/bash

set -exo pipefail

target="$1"
with_swig=

cd "$GITHUB_WORKSPACE/subversion"

case "$MATRIX_OS" in
ubuntu-*)
    pkgs="build-essential libtool libtool-bin libapr1-dev libaprutil1-dev
          libsqlite3-dev liblz4-dev libutf8proc-dev"
    case "$target" in
    swig-py)
        case "$MATRIX_PYVER" in
            2|2.*)  swig=swig3.0 ;;
            *)      swig=swig4.0 ;;
        esac
        ;;
    swig-*)
        swig=swig4.0
        ;;
    all|install)
        pkgs="$pkgs apache2-dev libserf-dev"
        swig=
        ;;
    esac
    test -n "$swig" && pkgs="$pkgs $swig"
    sudo apt-get update -qq
    sudo apt-get install -qq -y $pkgs
    sudo apt-get purge -qq -y subversion libsvn-dev
    with_apr=/usr/bin/apr-1-config
    with_apr_util=/usr/bin/apu-1-config
    test -n "$swig" && with_swig="/usr/bin/$swig"
    with_apxs=/usr/bin/apxs2
    with_sqlite=/usr
    parallel=3
    ;;
macos-*)
    pkgs="apr apr-util sqlite lz4 utf8proc"
    case "$target" in
    swig-py)
        case "$MATRIX_PYVER" in
            2|2.*)  swig=swig@3 ;;
            *)      swig=swig   ;;
        esac
        ;;
    swig-*)
        swig=swig
        ;;
    all|install)
        pkgs="$pkgs httpd"
        swig=
        ;;
    esac
    test -n "$swig" && pkgs="$pkgs $swig"
    brew update
    brew outdated $pkgs || brew upgrade $pkgs || :
    brew install $pkgs
    brew uninstall subversion || :
    with_apr="$(brew --prefix apr)/bin/apr-1-config"
    with_apr_util="$(brew --prefix apr-util)/bin/apu-1-config"
    test -n "$swig" && with_swig="$(brew --prefix "$swig")/bin/swig"
    with_apxs="$(brew --prefix httpd)/bin/apxs"
    with_sqlite="$(brew --prefix sqlite)"
    parallel=4
    ;;
*)
    echo "Unsupported $MATRIX_OS"
    ;;
esac

prefix="$HOME/svn"
test -d "$prefix/lib" || mkdir -p "$prefix/lib"
cflags=
if [ "$target" = install ]; then
    ldflags="-Wl,-rpath,$prefix/lib"
else
    ldflags="-L$prefix/lib -Wl,-rpath,$prefix/lib"
fi

if grep -q '[-]-with-swig-' configure.ac; then
    has_opt_swig_lang=y
    opt_swig_python="--without-swig-python"
    opt_swig_perl="--without-swig-perl"
    opt_swig_ruby="--without-swig-ruby"
else
    has_opt_swig_lang=n
    opt_swig_python="PYTHON=none"
    opt_swig_perl="PERL=none"
    opt_swig_ruby="RUBY=none"
fi
opt_swig="--without-swig"
opt_py3c="--without-py3c"
opt_apxs="--without-apxs"
opt_javahl="--disable-javahl"
opt_jdk="--without-jdk"
opt_junit="--without-junit"

case "$target" in
swig-py)
    opt_swig="--with-swig=$with_swig"
    if [ "$has_opt_swig_lang" = y ]; then
        opt_swig_python="--with-swig-python=python"
    else
        opt_swig_python="PYTHON=python"
    fi
    opt_py3c="--with-py3c=$GITHUB_WORKSPACE/py3c"
    use_installed_libs=y
    ;;
swig-rb)
    opt_swig="--with-swig=$with_swig"
    if [ "$has_opt_swig_lang" -eq 1 ]; then
        opt_swig_ruby="--with-swig-ruby=ruby"
    else
        opt_swig_ruby="RUBY=ruby"
    fi
    use_installed_libs=y
    case "$MATRIX_OS" in
    macos-*)
        cflags="$cflags -fdeclspec"
        ldflags="$ldflags -L$(ruby -rrbconfig -W0 -e "print RbConfig::CONFIG['libdir']")"
        ;;
    esac
    ;;
swig-pl)
    opt_swig="--with-swig=$with_swig"
    if [ "$has_opt_swig_lang" -eq 1 ]; then
        opt_swig_perl="--with-swig-perl=perl"
    else
        opt_swig_perl="PERL=perl"
    fi
    use_installed_libs=y
    cflags="$cflags -Wno-compound-token-split-by-macro"
    git apply "$GITHUB_WORKSPACE/.github/swig-pl-installed-libs.diff"
    ;;
javahl)
    opt_javahl="--enable-javahl"
    opt_jdk="--with-jdk=$JAVA_HOME"
    opt_junit="--with-junit=$prefix/lib/junit4.jar"
    use_installed_libs=y
    ;;
all|install)
    opt_apxs="--with-apxs=$with_apxs"
    use_installed_libs=n
    ;;
esac

mkdir -p subversion/bindings/swig/proxy || :
/bin/sh autogen.sh

if [ "$use_installed_libs" = y ]; then
    PATH="$prefix/bin:$PATH"
    export PATH
    installed_libs="$(cd "$prefix/lib" && \
                      echo libsvn_*.la | \
                      sed -e 's/-[^-]*\.la//g; s/ /,/g')"
    if [ "$target" = javahl ]; then
        python gen-make.py "$opt_jdk" "$opt_junit" --installed-libs="$installed_libs"
    else
        python gen-make.py --installed-libs="$installed_libs"
    fi
fi

./configure --prefix="$prefix" \
            --with-apr="$with_apr" --with-apr-util="$with_apr_util" \
            --with-sqlite="$with_sqlite" "$opt_swig" "$opt_py3c" "$opt_apxs" \
            "$opt_javahl" "$opt_jdk" "$opt_junit" \
            --without-doxygen --without-berkeley-db --without-gpg-agent \
            --without-gnome-keyring --without-kwallet \
            "$opt_swig_python" "$opt_swig_perl" "$opt_swig_ruby" \
            CFLAGS="$cflags" LDFLAGS="$ldflags"

case "$target" in
install)
    time make -j"$parallel" all
    make install
    curl -L -o "$prefix/lib/junit4.jar" \
        'https://search.maven.org/remotecontent?filepath=junit/junit/4.13.2/junit-4.13.2.jar'
    ;;
all)
    time make -j"$parallel" all
    time make check PARALLEL="$parallel"
    case "$MATRIX_OS" in
    ubuntu-*)
        make svnserveautocheck PARALLEL="$parallel"
        make davautocheck APACHE_MPM=event PARALLEL="$parallel"
        ;;
    esac
    ;;
swig-pl)
    time make -j"$parallel" "$target"
    time make check-"$target" TEST_VERBOSE=1
    ;;
swig-py)
    time make -j"$parallel" "$target"
    sed -e 's#/tests/run_all\.py#& -v#' Makefile >Makefile.new \
        && mv Makefile.new Makefile
    time make check-"$target"
    ;;
swig-rb)
    time make -j"$parallel" "$target"
    time make check-"$target" SWIG_RB_TEST_VERBOSE=v
    ;;
javahl)
    time make javahl
    time make check-javahl
    ;;
esac
