#!/usr/bin/env bash

set -euxo pipefail

readonly this_dir=`cd $(dirname $0); pwd`
readonly artifacts_dir=$this_dir/artifacts
readonly build_dir=$this_dir/build
readonly src_dir=$this_dir/src

mkdir -p $artifacts_dir
mkdir -p $build_dir
mkdir -p $src_dir

# Install pre-requisites packages
sudo apt-get install -y build-essential

echo "::group::Install CMake"
if [ ! -f $this_dir/cmake/bin/cmake ]
then
  cd $this_dir
  wget --quiet https://github.com/Kitware/CMake/releases/download/v3.18.4/cmake-3.18.4-Linux-x86_64.tar.gz
  tar xzf cmake-3.18.4-Linux-x86_64.tar.gz
  rm -f cmake-3.18.4-Linux-x86_64.tar.gz
  mv cmake-3.18.4-Linux-x86_64 cmake
fi
export CMAKE=$this_dir/cmake/bin/cmake
if [ ! -f $CMAKE ]
then
  echo "CMake installation went wrong" && false
fi
$CMAKE --version
echo "::endgroup::"

echo "::group::Install emscripten"
if [ ! -d $this_dir/emsdk ]
then
  cd $this_dir
  git clone https://github.com/emscripten-core/emsdk.git
fi
cd $this_dir/emsdk
# Use emsdk version from the original demo (Node 12)
git checkout --detach 2.0.9
if [ ! -f $this_dir/emsdk/upstream/emscripten/emcc ]
then
  ./emsdk install 2.0.9
fi
./emsdk activate 2.0.9
source $this_dir/emsdk/emsdk_env.sh
export EM_PREFIX=$EMSDK/upstream/emscripten/system
export EM_PKG_CONFIG_PATH="$EM_PREFIX/share/pkgconfig${EM_PKG_CONFIG_PATH:+:$EM_PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH="$EM_PKG_CONFIG_PATH${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
echo "::endgroup::"

export FORCE_JRL_CMAKEMODULES_UPDATE=false

# Helper to check out a specific tag or branch
checkout_ref()
{
  repo=$1
  ref=$2
  git -C "$repo" fetch --tags origin
  git -C "$repo" checkout "$ref"
}

# Helper function to build a CMake project
build_cmake_project()
{
  name=$1
  src=$2
  mkdir -p $build_dir/$name
  cd $build_dir/$name
  emcmake $CMAKE $src -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_INSTALL_PREFIX=${EM_PREFIX} ${CMAKE_OPTIONS} \
    "-DCMAKE_CROSSCOMPILING_EMULATOR=${EMSDK_NODE};--experimental-wasm-threads;--experimental-wasm-bulk-memory"
  emmake make -j$(nproc)
  emmake make install
}

# Helper to apply patches if needed
apply_local_patch()
{
  local name="$1"
  local repo="$2"
  local patch="$this_dir/patches/$name.patch"

  if [ ! -f "$patch" ]; then
    return 0
  fi

  echo "Applying local patch: $name"

  # Check if patch has already been applied
  if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "Patch already applied: $name"
    return 0
  fi

  # Apply after checking
  if git -C "$repo" apply --check "$patch"; then
    git -C "$repo" apply "$patch"
    echo "Patch successfully applied: $name"
  else
    echo "ERROR: Cannot apply patch $patch to $repo" >&2
    return 1
  fi
}

# Helper to build from git
build_git()
{
  echo "::group::Install $1"
  name=$1
  uri=$2
  branch=$3
  if [ ! -d $src_dir/$name ]
  then
    cd $src_dir
    # cloning without submodules first
    git clone $uri $src_dir/$name
  fi

  # checkout correct tag, then only pull submodules
  checkout_ref "$src_dir/$name" "$branch"
  git -C "$src_dir/$name" submodule sync --recursive
  git -C "$src_dir/$name" submodule update --init --recursive

  # apply patch if local changes needed
  apply_local_patch $name $src_dir/$name
  build_cmake_project $name $src_dir/$name
  echo "::endgroup::"
}

# Helper to build from a GitHub project
build_github()
{
  build_git `basename $1` https://github.com/$1 $2
}

# Helper to build from a tarball
build_release()
{
  echo "::group::Install $1"
  name=$1
  folder=$2
  uri=$3
  if [ ! -d $src_dir/$folder ]
  then
    cd $src_dir
    wget --quiet $uri -O - | tar -xz
  fi
  build_cmake_project $name $src_dir/$folder
  echo "::endgroup::"
}

echo "::group::Install Boost 1.74.0"
if [ ! -d $src_dir/boost_1_74_0 ]
then
  cd $src_dir
  if [ ! -f boost_1_74_0.tar.bz2 ]
  then
    wget --quiet https://archives.boost.io/release/1.74.0/source/boost_1_74_0.tar.bz2
  fi
  tar xjf boost_1_74_0.tar.bz2
fi
cd $src_dir/boost_1_74_0
if [ ! -f ./b2 ]
then
  ./bootstrap.sh || (cat bootstrap.log && false)
fi

# Options
export CMAKE_BUILD_TYPE=Release
export CXXFLAGS="-matomics -s USE_PTHREADS=1 -s DISABLE_EXCEPTION_CATCHING=0"
export LDFLAGS="-s USE_PTHREADS=1 -s DISABLE_EXCEPTION_CATCHING=0"

# Copy our patched jam configuration
cp $this_dir/emscripten.jam tools/build/src/tools/
emconfigure ./b2 toolset=emscripten --with-filesystem --with-timer --with-program_options --with-system --with-serialization --with-thread --with-test --prefix=$EM_PREFIX variant=release link=static install
echo "::endgroup::"

# Build f2c
echo "::group::Install libf2c"
if [ ! -d $src_dir/libf2c-emscripten ]
then
  cd $src_dir
  git clone https://github.com/gergondet/libf2c-emscripten.git libf2c-emscripten
fi
# Checkout specific commit just in case
checkout_ref "$src_dir/libf2c-emscripten" 42cc0e2adcee4e0f195bc30ea68b07e54f0d60af
cd $src_dir/libf2c-emscripten
emmake make -j$(nproc)
emmake make install
echo "::endgroup::"

# Build other dependencies

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF"
build_release eigen eigen-git-mirror-3.3.7 https://github.com/eigenteam/eigen-git-mirror/archive/3.3.7.tar.gz

build_release tinyxml2 tinyxml2-7.1.0 https://github.com/leethomason/tinyxml2/archive/7.1.0.tar.gz

export CMAKE_OPTIONS="-DBUILD_SHARED_LIBS=OFF -DASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT=OFF -DASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF -DASSIMP_BUILD_COLLADA_IMPORTER=ON -DASSIMP_BUILD_STL_IMPORTER=ON -DASSIMP_BUILD_ASSIMP_TOOLS=OFF -DASSIMP_BUILD_TESTS=OFF"
build_release assimp assimp-5.0.1 https://github.com/assimp/assimp/archive/v5.0.1.tar.gz

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF -DBUILD_SHARED_LIBS=OFF -DDISABLE_GEOS_INLINE=ON"
build_github libgeos/geos 3.8.0

export CMAKE_OPTIONS="-DYAML_CPP_BUILD_TESTS=OFF"
build_release yaml-cpp yaml-cpp-yaml-cpp-0.6.3 https://github.com/jbeder/yaml-cpp/archive/yaml-cpp-0.6.3.tar.gz

export CMAKE_OPTIONS="-DSPDLOG_BUILD_TESTS=OFF -DSPDLOG_BUILD_SHARED=OFF"
build_release spdlog spdlog-1.6.1 https://github.com/gabime/spdlog/archive/v1.6.1.tar.gz

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF -DBUILD_PYTHON_INTERFACE=OFF -DCURVES_WITH_PINOCCHIO_SUPPORT=OFF -DBUILD_SHARED_LIBS=OFF"
build_github loco-3d/ndcurves v2.0.0

export FORCE_JRL_CMAKEMODULES_UPDATE=true

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF -DPYTHON_BINDING=OFF -DUSE_F2C=ON -DINSTALL_DOCUMENTATION=OFF -DBUILD_SHARED_LIBS=OFF"
build_github jrl-umi3218/SpaceVecAlg v1.2.0
build_github jrl-umi3218/sch-core v1.2.0
build_github jrl-umi3218/eigen-qld v1.2.1
build_github jrl-umi3218/RBDyn v1.5.2
build_github jrl-umi3218/Tasks v1.5.0
build_github jrl-umi3218/mc_rbdyn_urdf v1.1.0
build_github jrl-umi3218/mc_rtc_data v1.0.4
build_github jrl-umi3218/eigen-quadprog v1.1.0
build_github jrl-umi3218/copra v1.2.2
build_github jrl-umi3218/state-observation v1.5.0

export CMAKE_OPTIONS="${CMAKE_OPTIONS} -DDISABLE_ROS=ON -DMC_RTC_BUILD_STATIC=ON -DMC_RTC_DISABLE_NETWORK=ON -DMC_RTC_DISABLE_STACKTRACE=ON -DJVRC_DESCRIPTION_PATH=/assets/jvrc_description -DMC_ENV_DESCRIPTION_PATH=/assets/mc_env_description -DMC_INT_OBJ_DESCRIPTION_PATH=/assets/mc_int_obj_description -DMC_PANDA_WITH_FRANKA=OFF -DMC_PANDA_DISABLE_XACRO=ON -DPANDA_DESCRIPTION_PATH=/assets/mc_panda"
if [ ! -d $src_dir/mc_rtc ]
then
  git clone https://github.com/gergondet/mc_rtc $src_dir/mc_rtc
fi
checkout_ref "$src_dir/mc_rtc" topic/wasm
git -C "$src_dir/mc_rtc" submodule sync --recursive
git -C "$src_dir/mc_rtc" submodule update --init --recursive
mkdir -p "$src_dir/mc_rtc/controllers" "$src_dir/mc_rtc/robots"
cd $src_dir/mc_rtc/controllers/
if [ ! -d lipm_walking_controller ]
then
  git clone https://github.com/gergondet/lipm_walking_controller
fi
checkout_ref "$src_dir/mc_rtc/controllers/lipm_walking_controller" topic/wasm
apply_local_patch "lipm_walking_controller" "$src_dir/mc_rtc/controllers/lipm_walking_controller"
cd $src_dir/mc_rtc/robots/
if [ ! -d mc_panda ]
then
  git clone https://github.com/gergondet/mc_panda
fi
checkout_ref "$src_dir/mc_rtc/robots/mc_panda" topic/NoFrankaOption
apply_local_patch "mc_panda" "$src_dir/mc_rtc/robots/mc_panda"
cd $this_dir
build_github gergondet/mc_rtc topic/wasm

# CMake does not generate proper dependencies for index.html so we force relinking
if [ -f $build_dir/mc_rtc-raylib/index.html ]
then
  rm -f $build_dir/mc_rtc-raylib/index.*
fi
build_github gergondet/mc_rtc-raylib master
cp $build_dir/mc_rtc-raylib/index.* $artifacts_dir/
cp -r $build_dir/mc_rtc-raylib/img/ $artifacts_dir
