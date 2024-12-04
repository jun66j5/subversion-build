#! /bin/bash

set -exo pipefail

target="$1"
workspace="$GITHUB_WORKSPACE"
prefix="$HOME/svn"
swig_arc="$workspace/arc/swig-$SWIG_VER.tar.gz"
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

if [ -n "$SVNARC" ]; then
    autogen=n
    arc="$workspace/arc/${SVNARC##*/}"
    tar xjf "$arc" -C "$workspace"
    mv "$workspace/subversion"-*.*.* "$workspace/subversion"
else
    autogen=y
fi

test -d "$prefix/lib" || mkdir -p "$prefix/lib"

case "$MATRIX_OS" in
ubuntu-*)
    pkgs="build-essential libtool libtool-bin libapr1-dev libaprutil1-dev
          libsqlite3-dev liblz4-dev libutf8proc-dev libserf-dev"
    case "$target" in
    swig-py)
        case "$MATRIX_PYVER" in
        2|2.*)
            pkgs="$pkgs python2.7-dev"
            swig_python=/usr/bin/python2.7
            autogen=y
            clean_swig_py=y
            ;;
        esac
        ;;
    swig-pl)
        pkgs="$pkgs libnsl-dev"
        ;;
    all|install)
        pkgs="$pkgs apache2-dev libserf-dev"
        ;;
    esac
    echo '::group::apt-get'
    sudo apt-get update -qq
    sudo apt-get install -qq -y $pkgs
    sudo apt-get purge -qq -y subversion libsvn-dev
    echo '::endgroup::'
    with_apr=/usr/bin/apr-1-config
    with_apu=/usr/bin/apu-1-config
    with_serf=yes
    with_apxs=/usr/bin/apxs2
    with_sqlite=
    sqlite_compat_ver=
    with_lz4=yes
    with_utf8proc=yes
    parallel=3
    ;;
macos-*)
    pkgs="autoconf automake libtool apr apr-util sqlite lz4 utf8proc openssl
          zlib"
    case "$target" in
    swig-py)
        case "$MATRIX_PYVER" in
        2|2.*)
            echo "Unsupported Python $MATRIX_PYVER on $MATRIX_OS" 1>&2
            exit 1
            ;;
        esac
        ;;
    all|install)
        pkgs="$pkgs httpd"
        ;;
    esac
    echo '::group::brew'
    brew update -q
    brew install -q $pkgs
    brew uninstall -q subversion 2>/dev/null || :
    echo '::endgroup::'
    prefix_apr="$(brew --prefix apr)"
    prefix_apu="$(brew --prefix apr-util)"
    with_apr="$prefix_apr/bin/apr-1-config"
    with_apu="$prefix_apu/bin/apu-1-config"
    with_serf="$prefix"
    with_apxs="$(brew --prefix httpd)/bin/apxs"
    with_sqlite="$(brew --prefix sqlite)"
    sqlite_compat_ver="$(/usr/bin/sqlite3 :memory: 'SELECT sqlite_version()')"
    with_lz4="$(brew --prefix lz4)"
    with_utf8proc="$(brew --prefix utf8proc)"
    parallel=4
    if [ -d "$workspace/serf" ]; then
        echo '::group::serf'
        python3 -m venv "$workspace/scons"
        "$workspace/scons/bin/pip" install scons
        scons="$workspace/scons/bin/scons"
        pushd "$workspace/serf"
        "$scons" -j "$parallel" \
                 SOURCE_LAYOUT=no \
                 APR_STATIC=no \
                 "PREFIX=$prefix" \
                 "LIBDIR=$prefix/lib" \
                 "APR=$prefix_apr" \
                 "APU=$prefix_apu" \
                 "OPENSSL=$(brew --prefix openssl)" \
                 "ZLIB=$(brew --prefix zlib)"
        "$scons" install
        echo '::endgroup::'
        popd
    fi
    ;;
*)
    echo "Unsupported $MATRIX_OS" 1>&2
    exit 1
    ;;
esac

if [ "$autogen" != y ]; then
    opt_swig=
elif [ -x "$prefix/bin/swig" ]; then
    opt_swig="--with-swig=$prefix/bin/swig"
elif [ -f "$swig_arc" ]; then
    echo '::group::swig'
    tar xzf "$swig_arc" -C "$workspace"
    pushd "$workspace/swig-$SWIG_VER"
    test -x configure || /bin/sh autogen.sh
    ./configure --prefix="$prefix" --without-pcre
    make -j"$parallel"
    make install
    popd
    echo '::endgroup::'
    opt_swig="--with-swig=$prefix/bin/swig"
else
    opt_swig='--without-swig'
fi

cd "$workspace/subversion"

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
    opt_junit="--with-junit=$workspace/arc/junit-$JUNIT_VER.jar"
    use_installed_libs=y
    ;;
all|install)
    opt_apxs="--with-apxs=$with_apxs"
    use_installed_libs=n
    ;;
esac

if [ "$autogen" = y ]; then
    mkdir -p subversion/bindings/swig/proxy || :
    echo '::group::autogen.sh'
    /bin/sh autogen.sh
    echo '::endgroup::'
fi

if [ "$use_installed_libs" = y ]; then
    echo '::group::gen-make.py'
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
    echo '::endgroup::'
fi

echo '::group::configure'
./configure --prefix="$prefix" \
            --with-apr="$with_apr" --with-apr-util="$with_apu" \
            --with-serf="$with_serf" --with-sqlite="$with_sqlite" \
            --enable-sqlite-compatibility-version="$sqlite_compat_ver" \
            --with-lz4="$with_lz4" --with-utf8proc="$with_utf8proc" \
            "$opt_swig" "$opt_py3c" "$opt_apxs" "$opt_javahl" "$opt_jdk" \
            "$opt_junit" --without-doxygen --without-berkeley-db \
            --without-gpg-agent --without-gnome-keyring --without-kwallet \
            "$opt_swig_python" "$opt_swig_perl" "$opt_swig_ruby" \
            CFLAGS="$cflags" LDFLAGS="$ldflags"
echo '::endgroup::'

do_make() {
    local rc=0
    echo "::group::make $*"
    time make "$@" || rc=$?
    echo '::endgroup::'
    return $rc
}

case "$target" in
install)
    do_make -j"$parallel" all
    do_make install
    ;;
all)
    do_make -j"$parallel" all
    rc=0
    for task in check svnserveautocheck davautocheck; do
        do_make "$task" PARALLEL="$parallel" APACHE_MPM=event || rc=$?
        for i in tests.log fails.log; do
            test -f "$i" && mv "$i" "$task-$i"
        done
    done
    exit $rc
    ;;
swig-pl)
    do_make -j"$parallel" swig-pl
    do_make check-swig-pl TEST_VERBOSE=1
    ;;
swig-py)
    if [ "$clean_swig_py" = y ]; then
        make clean-swig-py
    fi
    do_make -j"$parallel" swig-py
    sed_repl Makefile -e 's#/tests/run_all\.py#& -v#'
    do_make check-swig-py
    ;;
swig-rb)
    do_make -j"$parallel" swig-rb
    do_make check-swig-rb SWIG_RB_TEST_VERBOSE=v
    ;;
javahl)
    do_make javahl  # without -j option
    do_make check-all-javahl
    ;;
esac
