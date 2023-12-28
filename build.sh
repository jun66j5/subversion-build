#! /bin/bash

set -exo pipefail

target="$1"
workspace="$GITHUB_WORKSPACE"
prefix="$HOME/svn"
with_swig=
swig_python=python
swig_perl=perl
swig_ruby=ruby
clean_swig_py=n

sed_repl() {
    local orig="$1"
    local new="$orig.new~"
    shift
    sed "$@" "$orig" >"$new" && mv "$new" "$orig"
}

if [ -n "$INPUT_SVNARC" ]; then
    autogen=n
    test -d "$prefix/arc" || mkdir -p "$prefix/arc"
    arc="$prefix/arc/${INPUT_SVNARC##*/}"
    test -f "$arc" || curl -L -o "$arc" "$INPUT_SVNARC"
    tar xjf "$arc" -C "$workspace"
    mv "$workspace/subversion"-*.*.* "$workspace/subversion"
else
    autogen=y
fi
cd "$workspace/subversion"

case "$MATRIX_OS" in
ubuntu-*)
    pkgs="build-essential libtool libtool-bin libapr1-dev libaprutil1-dev
          libsqlite3-dev liblz4-dev libutf8proc-dev libserf-dev"
    case "$target" in
    swig-py)
        case "$MATRIX_PYVER" in
        2|2.*)
            pkgs="$pkgs python2.7-dev"
            swig=swig3.0
            swig_python=/usr/bin/python2.7
            autogen=y
            clean_swig_py=y
            ;;
        *)
            swig=swig4.0
            ;;
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
    if [ -n "$swig" -a "$autogen" = y ]; then
        pkgs="$pkgs $swig"
        with_swig="/usr/bin/$swig"
    fi
    sudo apt-get update -qq
    sudo apt-get install -qq -y $pkgs
    sudo apt-get purge -qq -y subversion libsvn-dev
    with_apr=/usr/bin/apr-1-config
    with_apr_util=/usr/bin/apu-1-config
    with_apxs=/usr/bin/apxs2
    with_sqlite=/usr
    parallel=3
    ;;
macos-*)
    pkgs="apr apr-util sqlite lz4 utf8proc"
    case "$target" in
    swig-py)
        case "$MATRIX_PYVER" in
        2|2.*)
            echo "Unsupported Python $MATRIX_PYVER on $MATRIX_OS" 1>&2
            exit 1
            ;;
        esac
        swig=swig
        ;;
    swig-*)
        swig=swig
        ;;
    all|install)
        pkgs="$pkgs httpd"
        swig=
        ;;
    esac
    if [ -n "$swig" -a "$autogen" = y ]; then
        pkgs="$pkgs $swig"
        with_swig="$(brew --prefix "$swig")/bin/swig"
    fi
    brew update
    brew outdated $pkgs || brew upgrade $pkgs || :
    brew install $pkgs
    brew uninstall subversion || :
    with_apr="$(brew --prefix apr)/bin/apr-1-config"
    with_apr_util="$(brew --prefix apr-util)/bin/apu-1-config"
    with_apxs="$(brew --prefix httpd)/bin/apxs"
    with_sqlite="$(brew --prefix sqlite)"
    parallel=4
    ;;
*)
    echo "Unsupported $MATRIX_OS" 1>&2
    exit 1
    ;;
esac

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
if [ "$autogen" != y ]; then
    opt_swig=
elif [ -n "$with_swig" ]; then
    opt_swig="--with-swig=$with_swig"
else
    opt_swig='--without-swig'
fi
opt_py3c="--without-py3c"
opt_apxs="--without-apxs"
opt_javahl="--disable-javahl"
opt_jdk="--without-jdk"
opt_junit="--without-junit"

case "$target" in
swig-py)
    if [ "$has_opt_swig_lang" = y ]; then
        opt_swig_python="--with-swig-python=$swig_python"
    else
        opt_swig_python="PYTHON=$swig_python"
    fi
    opt_py3c="--with-py3c=$workspace/py3c"
    use_installed_libs=y
    ;;
swig-rb)
    if [ "$has_opt_swig_lang" = y ]; then
        opt_swig_ruby="--with-swig-ruby=$swig_ruby"
    else
        opt_swig_ruby="RUBY=$swig_ruby"
    fi
    use_installed_libs=y
    case "$MATRIX_OS" in
    macos-*)
        cflags="$cflags -fdeclspec -Wno-unused-but-set-variable"
        ldflags="$ldflags -L$(ruby -rrbconfig -W0 -e "print RbConfig::CONFIG['libdir']")"
        ;;
    esac
    ;;
swig-pl)
    if [ "$has_opt_swig_lang" = y ]; then
        opt_swig_perl="--with-swig-perl=$swig_perl"
    else
        opt_swig_perl="PERL=$swig_perl"
    fi
    use_installed_libs=y
    cflags="$cflags -Wno-compound-token-split-by-macro"
    sed_repl subversion/bindings/swig/perl/native/Makefile.PL.in \
             -e "s#^my @ldpaths = (#&'@prefix@/lib', #"
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

if [ "$autogen" = y ]; then
    mkdir -p subversion/bindings/swig/proxy || :
    /bin/sh autogen.sh
fi

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
            --with-sqlite="$with_sqlite" $opt_swig "$opt_py3c" "$opt_apxs" \
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
    case "$MATRIX_OS" in
    ubuntu-*)
        tasks='check svnserveautocheck davautocheck'
        ;;
    macos-*)
        tasks='check svnserveautocheck'
        ;;
    esac
    rc=0
    for task in $tasks; do
        time make $task PARALLEL="$parallel" APACHE_MPM=event || rc=1
        for i in tests.log fails.log; do
            test -f "$i" && mv -v "$i" "$task-$i"
        done
    done
    exit $rc
    ;;
swig-pl)
    time make -j"$parallel" swig-pl
    time make check-swig-pl TEST_VERBOSE=1
    ;;
swig-py)
    if [ "$clean_swig_py" = y ]; then
        make clean-swig-py
    fi
    time make -j"$parallel" swig-py
    sed_repl Makefile -e 's#/tests/run_all\.py#& -v#'
    time make check-swig-py
    ;;
swig-rb)
    time make -j"$parallel" swig-rb
    time make check-swig-rb SWIG_RB_TEST_VERBOSE=v
    ;;
javahl)
    time make javahl  # without -j option
    time make check-all-javahl
    ;;
esac
