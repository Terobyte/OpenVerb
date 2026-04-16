# ---------------------------------------------------------------------------
# OpenVerb Engine — Unit Tests
# ---------------------------------------------------------------------------
include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
)
# Prevent GoogleTest from overriding parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

include(GoogleTest)

# ---------------------------------------------------------------------------
# Collect all test_*.cpp files and create one executable per test file
# ---------------------------------------------------------------------------
file(GLOB TEST_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/test_*.cpp"
)

foreach(test_src ${TEST_SOURCES})
    get_filename_component(test_name ${test_src} NAME_WE)
    add_executable(${test_name} ${test_src})
    target_link_libraries(${test_name} PRIVATE
        gtest_main
        openverb-engine-lib
    )
    target_compile_definitions(${test_name} PRIVATE
        OPENVERB_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/.."
    )
    if(test_name STREQUAL "test_capture")
        gtest_discover_tests(${test_name} PROPERTIES DISABLED TRUE)
    else()
        gtest_discover_tests(${test_name})
    endif()
endforeach()

# ---------------------------------------------------------------------------
# Integration test: pass the compile flag so the #ifdef block is active.
# The test_integration target is created by the foreach above (it matches
# the test_*.cpp glob); this block is a no-op when the option is OFF.
# ---------------------------------------------------------------------------
if(OPENVERB_INTEGRATION_TESTS)
    target_compile_definitions(test_integration PRIVATE OPENVERB_INTEGRATION_TESTS)
    if(TARGET test_ipc_integration)
        target_compile_definitions(test_ipc_integration PRIVATE OPENVERB_INTEGRATION_TESTS)
    endif()
endif()
