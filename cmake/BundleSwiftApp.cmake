foreach(required_var IN ITEMS SWIFT_EXECUTABLE SOURCE_DIR BUILD_PATH APP_BUNDLE_DIR APP_NAME)
    if(NOT DEFINED ${required_var} OR "${${required_var}}" STREQUAL "")
        message(FATAL_ERROR "Missing required variable: ${required_var}")
    endif()
endforeach()

if(NOT DEFINED SWIFT_CONFIGURATION OR "${SWIFT_CONFIGURATION}" STREQUAL "")
    set(SWIFT_CONFIGURATION "release")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env
        "CLANG_MODULE_CACHE_PATH=${BUILD_PATH}/ModuleCache"
        "${SWIFT_EXECUTABLE}" build -c "${SWIFT_CONFIGURATION}"
        --disable-sandbox
        --package-path "${SOURCE_DIR}"
        --build-path "${BUILD_PATH}"
    WORKING_DIRECTORY "${SOURCE_DIR}"
    RESULT_VARIABLE build_result
)

if(NOT build_result EQUAL 0)
    message(FATAL_ERROR "swift build failed with exit code ${build_result}")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env
        "CLANG_MODULE_CACHE_PATH=${BUILD_PATH}/ModuleCache"
        "${SWIFT_EXECUTABLE}" build -c "${SWIFT_CONFIGURATION}"
        --disable-sandbox
        --package-path "${SOURCE_DIR}"
        --build-path "${BUILD_PATH}"
        --show-bin-path
    WORKING_DIRECTORY "${SOURCE_DIR}"
    OUTPUT_VARIABLE swift_bin_path
    ERROR_VARIABLE swift_bin_error
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE bin_path_result
)

if(NOT bin_path_result EQUAL 0)
    message(FATAL_ERROR "Could not resolve Swift binary path: ${swift_bin_error}")
endif()

set(executable_path "${swift_bin_path}/${APP_NAME}")
if(NOT EXISTS "${executable_path}")
    message(FATAL_ERROR "Expected Swift executable does not exist: ${executable_path}")
endif()

file(REMOVE_RECURSE "${APP_BUNDLE_DIR}")
file(MAKE_DIRECTORY
    "${APP_BUNDLE_DIR}/Contents/MacOS"
    "${APP_BUNDLE_DIR}/Contents/Resources"
)

file(COPY "${executable_path}" DESTINATION "${APP_BUNDLE_DIR}/Contents/MacOS")
file(CHMOD "${APP_BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
    PERMISSIONS
        OWNER_READ OWNER_WRITE OWNER_EXECUTE
        GROUP_READ GROUP_EXECUTE
        WORLD_READ WORLD_EXECUTE
)
configure_file(
    "${SOURCE_DIR}/Resources/Info.plist"
    "${APP_BUNDLE_DIR}/Contents/Info.plist"
    COPYONLY
)
file(COPY "${SOURCE_DIR}/Resources/AllTheThings.icns" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/GameCoreTechLogo.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/NibGeneratedMasterSheet.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/NibIdleMainLoopStrip.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/NibIdleBlinkFidgetStrip.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/NibIdleAntennaFidgetStrip.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/NibIdleFileFinderSparkStrip.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(COPY "${SOURCE_DIR}/Resources/NibIdleVictoryBounceStrip.png" DESTINATION "${APP_BUNDLE_DIR}/Contents/Resources")
file(WRITE "${APP_BUNDLE_DIR}/Contents/PkgInfo" "APPL????")

find_program(CODESIGN_EXECUTABLE codesign)
if(CODESIGN_EXECUTABLE)
    execute_process(
        COMMAND "${CODESIGN_EXECUTABLE}" --force --deep --sign - "${APP_BUNDLE_DIR}"
        WORKING_DIRECTORY "${SOURCE_DIR}"
        RESULT_VARIABLE codesign_result
    )

    if(NOT codesign_result EQUAL 0)
        message(FATAL_ERROR "codesign failed with exit code ${codesign_result}")
    endif()
endif()

message(STATUS "Built ${APP_BUNDLE_DIR}")
