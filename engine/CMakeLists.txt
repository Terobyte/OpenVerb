cmake_minimum_required(VERSION 3.16)
project(openverb-engine VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
option(OPENVERB_BUILD_TESTS      "Build OpenVerb unit tests"        ON)
option(OPENVERB_INTEGRATION_TESTS "Build OpenVerb integration tests" OFF)

# ---------------------------------------------------------------------------
# Version header  (generates src/config/version.h in the build tree)
# ---------------------------------------------------------------------------
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/config/version.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/src/config/version.h
)

# ---------------------------------------------------------------------------
# Third-party: llama.cpp  (Metal-accelerated inference)
# ---------------------------------------------------------------------------
# Disable llama.cpp extras we don't need
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS    OFF CACHE BOOL "" FORCE)

# Enable Metal backend on macOS
set(GGML_METAL ON CACHE BOOL "Enable Metal backend for ggml" FORCE)

add_subdirectory(third_party/llama.cpp)

# ---------------------------------------------------------------------------
# Third-party: mtmd  (llama.cpp multimodal audio+vision library)
#
# mtmd lives under third_party/llama.cpp/tools/mtmd/ and is only compiled
# when LLAMA_BUILD_TOOLS=ON — which we deliberately keep OFF to avoid
# building the many CLI executables that depend on `common`.
# We therefore build the mtmd static library directly here, listing the same
# sources as tools/mtmd/CMakeLists.txt but skipping the executables.
# ---------------------------------------------------------------------------
set(MTMD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/tools/mtmd)
file(GLOB MTMD_MODEL_SOURCES CONFIGURE_DEPENDS
    "${MTMD_DIR}/models/*.cpp"
)
add_library(mtmd STATIC
    ${MTMD_DIR}/mtmd.cpp
    ${MTMD_DIR}/mtmd-audio.cpp
    ${MTMD_DIR}/mtmd-image.cpp
    ${MTMD_DIR}/mtmd-helper.cpp
    ${MTMD_DIR}/clip.cpp
    ${MTMD_MODEL_SOURCES}
)
target_link_libraries(mtmd PUBLIC ggml llama)
target_include_directories(mtmd PUBLIC ${MTMD_DIR})
target_include_directories(mtmd PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/vendor
)
target_compile_features(mtmd PRIVATE cxx_std_17)
if(NOT MSVC)
    target_compile_options(mtmd PRIVATE -Wno-cast-qual)
endif()

# ---------------------------------------------------------------------------
# Third-party: nlohmann/json  (header-only)
# ---------------------------------------------------------------------------
add_library(nlohmann_json INTERFACE)
target_include_directories(nlohmann_json SYSTEM INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/json/single_include
)

# ---------------------------------------------------------------------------
# Third-party: WebRTC VAD  (voice activity detection, C sources)
# ---------------------------------------------------------------------------
file(GLOB WEBRTC_VAD_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/webrtc_vad/*.c"
)

add_library(webrtc_vad_lib STATIC ${WEBRTC_VAD_SOURCES})
target_include_directories(webrtc_vad_lib PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/webrtc_vad
)

# ---------------------------------------------------------------------------
# OpenVerb Engine Library  (static, all src/**/*.cpp except main.cpp)
# ---------------------------------------------------------------------------
file(GLOB_RECURSE ENGINE_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp"
)
list(FILTER ENGINE_SOURCES EXCLUDE REGEX ".*main\\.cpp$")

add_library(openverb-engine-lib STATIC ${ENGINE_SOURCES})

# Public headers & generated version.h
target_include_directories(openverb-engine-lib PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_BINARY_DIR}/src
)
target_link_libraries(openverb-engine-lib PUBLIC
    llama
    mtmd
    nlohmann_json
    webrtc_vad_lib
)

# macOS frameworks (needed for Metal / Accelerate / Audio)
if(APPLE)
    target_link_libraries(openverb-engine-lib PUBLIC
        "-framework Foundation"
        "-framework Accelerate"
        "-framework Metal"
        "-framework MetalKit"
        "-framework CoreAudio"
        "-framework AudioToolbox"
    )
endif()

# ---------------------------------------------------------------------------
# OpenVerb Engine Executable  (thin wrapper around the library)
# ---------------------------------------------------------------------------
add_executable(openverb-engine src/main.cpp)
target_link_libraries(openverb-engine PRIVATE openverb-engine-lib)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
if(OPENVERB_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
