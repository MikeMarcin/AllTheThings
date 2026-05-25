cmake_minimum_required(VERSION 3.25)

project(AllTheThings LANGUAGES NONE)

set(APP_NAME "AllTheThings")
set(APP_BUNDLE_DIR "${CMAKE_SOURCE_DIR}/build/${APP_NAME}.app" CACHE PATH "Generated macOS app bundle path")
set(SWIFT_BUILD_ROOT "${CMAKE_BINARY_DIR}/swiftpm" CACHE PATH "SwiftPM build output root")

find_program(SWIFT_EXECUTABLE swift REQUIRED)
find_program(OPEN_EXECUTABLE open)

enable_testing()

add_test(
    NAME SwiftPackageTests
    COMMAND "${SWIFT_EXECUTABLE}" test
        --package-path "${CMAKE_SOURCE_DIR}"
        --build-path "${SWIFT_BUILD_ROOT}/debug"
)

add_custom_target(check
    COMMAND "${SWIFT_EXECUTABLE}" test
        --package-path "${CMAKE_SOURCE_DIR}"
        --build-path "${SWIFT_BUILD_ROOT}/debug"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    USES_TERMINAL
)

add_custom_target(app
    COMMAND "${CMAKE_COMMAND}"
        "-DSWIFT_EXECUTABLE=${SWIFT_EXECUTABLE}"
        "-DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
        "-DBUILD_PATH=${SWIFT_BUILD_ROOT}/release"
        "-DAPP_BUNDLE_DIR=${APP_BUNDLE_DIR}"
        "-DAPP_NAME=${APP_NAME}"
        -P "${CMAKE_SOURCE_DIR}/cmake/BundleSwiftApp.cmake"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    BYPRODUCTS "${APP_BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
    USES_TERMINAL
)

if(OPEN_EXECUTABLE)
    add_custom_target(run
        COMMAND "${OPEN_EXECUTABLE}" "${APP_BUNDLE_DIR}"
        DEPENDS app
        USES_TERMINAL
    )
endif()

add_custom_target(clean-app
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${APP_BUNDLE_DIR}"
)
