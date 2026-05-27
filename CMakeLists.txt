project(MobileUI LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)

# Use that find_package() call in the root project:
find_package(Qt6 6.7 REQUIRED COMPONENTS Core Gui Qml)

################################################################################

# Generic dependencies
set(CORE_LIBRARIES Qt::Core Qt::Gui Qt::Qml)

# Generic sources
set(CORE_SOURCES
    MobileUI.h
    MobileUI.cpp
    pushnotifications.h
    pushnotifications.cpp)

# OS specific sources & dependencies
if(ANDROID)
    set(PLATFORM_SOURCES
        MobileUI_android.cpp
        pushnotification_android.h
        pushnotification_android.cpp)
elseif(IOS)
    set(PLATFORM_SOURCES
        MobileUI_ios.mm
        pushnotification_ios.h
        pushnotification_ios.mm
        mobileuiappdelegate_ios.h
        mobileuiappdelegate_ios.mm)
    set(PLATFORM_LIBRARIES "-framework UIKit -framework UserNotifications -framework Intents")
else()
    set(PLATFORM_SOURCES MobileUI_dummy.cpp)
endif()

################################################################################

add_library(MobileUI OBJECT ${CORE_SOURCES} ${PLATFORM_SOURCES})
add_library(MobileUI::MobileUI ALIAS MobileUI)

target_link_libraries(MobileUI PRIVATE ${CORE_LIBRARIES} ${PLATFORM_LIBRARIES})
target_include_directories(MobileUI PUBLIC ${CMAKE_CURRENT_LIST_DIR})

if(ANDROID)
    # Publish the MobileUI java helpers to mavenLocal
    option(MOBILEUI_ANDROID_PUBLISH "Publish MobileUI Android helper to mavenLocal" ON)
    set(MOBILEUI_ANDROID_GRADLE_DIR "${CMAKE_CURRENT_LIST_DIR}/android/qt6")
    set(MOBILEUI_ANDROID_GRADLEW "${MOBILEUI_ANDROID_GRADLE_DIR}/gradlew")
    if(NOT EXISTS "${MOBILEUI_ANDROID_GRADLEW}")
        message(FATAL_ERROR "Gradle wrapper not found. Expected ${MOBILEUI_ANDROID_GRADLEW}.")
    endif()
    add_custom_target(mobileui_android_publish ALL
        COMMAND ${CMAKE_COMMAND} -E chdir "${MOBILEUI_ANDROID_GRADLE_DIR}"
                "${MOBILEUI_ANDROID_GRADLEW}" publishToMavenLocal
        COMMENT "Publishing MobileUI Android helper to mavenLocal"
    )
    if(MOBILEUI_ANDROID_PUBLISH)
        add_dependencies(MobileUI mobileui_android_publish)
    endif()
endif()
