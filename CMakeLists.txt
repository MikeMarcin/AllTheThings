cmake_minimum_required(VERSION 3.25)

project(AllTheThings LANGUAGES C)

set(APP_NAME "AllTheThings")
set(APP_BUNDLE_DIR "${CMAKE_SOURCE_DIR}/build/${APP_NAME}.app" CACHE PATH "Generated macOS app bundle path")
set(APP_DEBUG_BUNDLE_DIR "${CMAKE_SOURCE_DIR}/build/${APP_NAME}-Debug.app" CACHE PATH "Generated debug macOS app bundle path")
set(SWIFT_BUILD_ROOT "${CMAKE_BINARY_DIR}/swiftpm" CACHE PATH "SwiftPM build output root")

find_program(SWIFT_EXECUTABLE swift REQUIRED)
find_program(OPEN_EXECUTABLE open)

enable_testing()

add_test(
    NAME SwiftPackageTests
    COMMAND "${CMAKE_COMMAND}" -E env
        "CLANG_MODULE_CACHE_PATH=${SWIFT_BUILD_ROOT}/debug/ModuleCache"
        "${SWIFT_EXECUTABLE}" test
        --disable-sandbox
        --no-parallel
        --package-path "${CMAKE_SOURCE_DIR}"
        --build-path "${SWIFT_BUILD_ROOT}/debug"
)

add_custom_target(check
    COMMAND "${CMAKE_COMMAND}" -E env
        "CLANG_MODULE_CACHE_PATH=${SWIFT_BUILD_ROOT}/debug/ModuleCache"
        "${SWIFT_EXECUTABLE}" test
        --disable-sandbox
        --no-parallel
        --package-path "${CMAKE_SOURCE_DIR}"
        --build-path "${SWIFT_BUILD_ROOT}/debug"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    USES_TERMINAL
)

add_custom_target(app
    COMMAND "${CMAKE_COMMAND}"
        "-DSWIFT_EXECUTABLE=${SWIFT_EXECUTABLE}"
        "-DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
        "-DSWIFT_CONFIGURATION=release"
        "-DBUILD_PATH=${SWIFT_BUILD_ROOT}/release"
        "-DAPP_BUNDLE_DIR=${APP_BUNDLE_DIR}"
        "-DAPP_NAME=${APP_NAME}"
        -P "${CMAKE_SOURCE_DIR}/cmake/BundleSwiftApp.cmake"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    BYPRODUCTS "${APP_BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
    USES_TERMINAL
)

set(APP_BUNDLE_DIR_FOR_LAUNCHER "${APP_BUNDLE_DIR}")
configure_file(
    "${CMAKE_SOURCE_DIR}/cmake/LaunchApp.c.in"
    "${CMAKE_BINARY_DIR}/LaunchAllTheThings.c"
    @ONLY
)
unset(APP_BUNDLE_DIR_FOR_LAUNCHER)

add_executable(LaunchAllTheThings "${CMAKE_BINARY_DIR}/LaunchAllTheThings.c")
add_dependencies(LaunchAllTheThings app)

add_custom_target(app-debug
    COMMAND "${CMAKE_COMMAND}"
        "-DSWIFT_EXECUTABLE=${SWIFT_EXECUTABLE}"
        "-DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
        "-DSWIFT_CONFIGURATION=debug"
        "-DBUILD_PATH=${SWIFT_BUILD_ROOT}/debug-app"
        "-DAPP_BUNDLE_DIR=${APP_DEBUG_BUNDLE_DIR}"
        "-DAPP_NAME=${APP_NAME}"
        -P "${CMAKE_SOURCE_DIR}/cmake/BundleSwiftApp.cmake"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    BYPRODUCTS "${APP_DEBUG_BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
    USES_TERMINAL
)

set(APP_BUNDLE_DIR_FOR_LAUNCHER "${APP_DEBUG_BUNDLE_DIR}")
configure_file(
    "${CMAKE_SOURCE_DIR}/cmake/LaunchApp.c.in"
    "${CMAKE_BINARY_DIR}/DebugAllTheThings.c"
    @ONLY
)
unset(APP_BUNDLE_DIR_FOR_LAUNCHER)

add_executable(DebugAllTheThings "${CMAKE_BINARY_DIR}/DebugAllTheThings.c")
add_dependencies(DebugAllTheThings app-debug)

if(OPEN_EXECUTABLE)
    add_custom_target(run
        COMMAND "${CMAKE_COMMAND}" -E echo "Launching ${APP_BUNDLE_DIR}"
        COMMAND "${OPEN_EXECUTABLE}" -W "${APP_BUNDLE_DIR}"
        DEPENDS app
        USES_TERMINAL
    )
endif()

add_custom_target(clean-app
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${APP_BUNDLE_DIR}" "${APP_DEBUG_BUNDLE_DIR}"
)
