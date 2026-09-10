allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// agora_rtc_engine's own android/build.gradle reads this via
// `safeExtGet('compileSdkVersion', 31)` — it does not follow the app's
// flutter.compileSdkVersion, so without this it compiles against API 31 and
// fails against newer androidx (lifecycle 2.7+ needs 34). Every subproject
// module in this build picks up the same value through that helper.
rootProject.extra["compileSdkVersion"] = 36

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
