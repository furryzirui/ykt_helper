allprojects {
    repositories {
        mavenCentral()
        google()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    // Older Flutter plugins still declare private AGP/Kotlin classpaths. Use the
    // application's toolchain for every Android plugin to keep a single version.
    buildscript {
        repositories {
            mavenCentral()
            google()
        }
        configurations.configureEach {
            resolutionStrategy.force(
                "com.android.tools.build:gradle:9.3.1",
                "org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.20",
            )
        }
    }
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
