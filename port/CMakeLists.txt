# ============================================================================
#  Silent Storm, native macOS build (arm64, Metal)
#
#  Configure:  cmake -S port -B <build dir> -G Ninja
#  Build:      cmake --build <build dir>
#
#  Engine sources come from the repository root (the community reconstruction, kept close to
#  upstream). Windows APIs the engine calls are implemented natively in port/platform.
# ============================================================================
cmake_minimum_required(VERSION 3.24)
project(SilentStormMac C CXX OBJC OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "This build is macOS only; Windows uses the root CMakeLists.txt.")
endif()

set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_EXTENSIONS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

get_filename_component(root "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(port "${CMAKE_CURRENT_SOURCE_DIR}")
include("${root}/sources.cmake")

# Engine dialect: the 2003 sources rely on MSVC extensions (__int64, __declspec, anonymous structs),
# use 'or'/'and' as identifiers, and pass addresses of temporaries to by-pointer helpers.
set(S2_ENGINE_FLAGS -fms-extensions -fdelayed-template-parsing -fno-operator-names -Wno-address-of-temporary -w)
set(S2_ENGINE_DEFINES NDEBUG externA5=extern)
set(S2_SYSTEM_INCLUDES "${port}/compat/mac" "${port}/platform/include" "${port}/compat"
    "${root}/third_party/zlib" "${root}/third_party/libpng" "${root}/third_party/squish"
    "${root}/third_party/lifestudio/include" "${root}/third_party/fmod/include" "${root}/third_party/bink/include" "${root}/third_party")

# Files whose job is Windows-specific; port/platform supplies macOS equivalents of what they provide.
set(S2_WINDOWS_ONLY
  Main/SplashScreenDialog.cpp
  Game/WinFrame.cpp
)

# --- third party -----------------------------------------------------------
file(GLOB zlib_src "${root}/third_party/zlib/*.c")
add_library(s2zlib STATIC ${zlib_src})
target_include_directories(s2zlib PUBLIC "${root}/third_party/zlib")
target_compile_options(s2zlib PRIVATE -w)

file(GLOB png_src "${root}/third_party/libpng/*.c")
list(FILTER png_src EXCLUDE REGEX "(pnggccrd|pngvcrd|pngtest)\\.c$")
add_library(s2png STATIC ${png_src})
target_include_directories(s2png PUBLIC "${root}/third_party/libpng")
target_link_libraries(s2png PUBLIC s2zlib)
target_compile_definitions(s2png PRIVATE PNG_NO_MMX_CODE externA5=extern)
target_compile_options(s2png PRIVATE -w)

file(GLOB squish_src "${root}/third_party/squish/squish/*.cpp")
add_library(s2squish STATIC ${squish_src})
target_include_directories(s2squish PUBLIC "${root}/third_party/squish" PRIVATE "${root}/third_party/squish/squish")
target_compile_options(s2squish PRIVATE -w)

# --- engine modules ----------------------------------------------------------
function(s2_engine_module name)
  set(src "")
  foreach(f IN LISTS ${name}_SRC)
    set(rel "${name}/${f}")
    list(FIND S2_WINDOWS_ONLY "${rel}" idx)
    if(idx EQUAL -1)
      list(APPEND src "${root}/${rel}")
    endif()
  endforeach()
  add_library(${name} STATIC ${src})
  target_compile_options(${name} PRIVATE ${S2_ENGINE_FLAGS})
  target_compile_definitions(${name} PRIVATE ${S2_ENGINE_DEFINES})
  # the module's own folder is searched only for "quoted" includes, so Main/time.h cannot shadow <time.h>
  target_compile_options(${name} PRIVATE "-iquote${root}/${name}")
  target_include_directories(${name} SYSTEM PRIVATE ${S2_SYSTEM_INCLUDES})
endfunction()

foreach(m Misc FileIO MiscDll Image ADOImport FModSound Input Script DBFormat Main)
  s2_engine_module(${m})
endforeach()

# --- platform layer ----------------------------------------------------------
file(GLOB_RECURSE platform_src CONFIGURE_DEPENDS "${port}/platform/src/*.cpp" "${port}/platform/src/*.mm" "${port}/platform/src/*.m")
add_library(s2platform STATIC ${platform_src})
target_include_directories(s2platform PUBLIC ${S2_SYSTEM_INCLUDES} "${root}")
target_compile_options(s2platform PRIVATE -fms-extensions -fdelayed-template-parsing -fno-operator-names -Wno-address-of-temporary -Wno-ignored-attributes -Wno-nullability-completeness
  $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_compile_definitions(s2platform PRIVATE ${S2_ENGINE_DEFINES})

# --- game executable -----------------------------------------------------------
set(game_src "")
foreach(f IN LISTS Game_SRC)
  list(FIND S2_WINDOWS_ONLY "Game/${f}" idx)
  if(idx EQUAL -1)
    list(APPEND game_src "${root}/Game/${f}")
  endif()
endforeach()
set(S2_ICON "${port}/resources/SilentStorm.icns")
set_source_files_properties(${S2_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
add_executable(SilentStorm MACOSX_BUNDLE ${game_src} ${S2_ICON})
target_compile_options(SilentStorm PRIVATE ${S2_ENGINE_FLAGS} "-iquote${root}/Game")
target_compile_definitions(SilentStorm PRIVATE ${S2_ENGINE_DEFINES})
target_include_directories(SilentStorm SYSTEM PRIVATE ${S2_SYSTEM_INCLUDES})
# Main registers its classes through static constructors, so keep every object file
target_link_libraries(SilentStorm PRIVATE
  "$<LINK_LIBRARY:WHOLE_ARCHIVE,Main>"
  ADOImport DBFormat FileIO FModSound Input MiscDll Misc Script Image
  s2platform s2squish s2png s2zlib
  "-framework Cocoa" "-framework Metal" "-framework QuartzCore" "-framework GameController"
  "-framework AudioToolbox" "-framework AVFoundation" "-framework CoreAudio" "-framework IOKit" "-framework Carbon" "-framework ImageIO" "-framework UniformTypeIdentifiers" "-framework CoreMedia" "-framework CoreVideo" "-framework MetalFX" iconv)
set_target_properties(SilentStorm PROPERTIES
  OUTPUT_NAME "Silent Storm"
  MACOSX_BUNDLE_INFO_PLIST "${port}/resources/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "Silent Storm"
  MACOSX_BUNDLE_GUI_IDENTIFIER "org.silentstorm.mac"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "1.2"
  MACOSX_BUNDLE_BUNDLE_VERSION "1")

# --- tools ------------------------------------------------------------------------
# texpack: HD texture pipeline (extract textures, rebuild upscaled ones as MMP files); see port/tools/texpack
add_executable(s2texpack "${port}/tools/texpack/texpack.mm" "${port}/tools/texpack/texpack_pkg.cpp")
set_source_files_properties("${port}/tools/texpack/texpack_pkg.cpp" PROPERTIES COMPILE_OPTIONS "${S2_ENGINE_FLAGS};-iquote${root}/FileIO")
target_compile_definitions(s2texpack PRIVATE ${S2_ENGINE_DEFINES})
target_include_directories(s2texpack SYSTEM PRIVATE ${S2_SYSTEM_INCLUDES} "${root}/third_party/squish/squish")
target_compile_options(s2texpack PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(s2texpack PRIVATE FileIO MiscDll Misc s2platform s2squish
  "-framework Foundation" "-framework CoreGraphics" "-framework ImageIO" "-framework UniformTypeIdentifiers"
  "-framework Cocoa" "-framework Metal" "-framework QuartzCore" "-framework AudioToolbox" "-framework AVFoundation" "-framework CoreAudio"
  "-framework IOKit" "-framework Carbon" "-framework CoreMedia" "-framework CoreVideo" "-framework MetalFX" "-framework GameController" iconv)
