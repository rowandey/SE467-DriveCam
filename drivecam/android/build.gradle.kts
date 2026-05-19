allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

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

// AGP 8+ requires every android library module to declare a namespace in its
// build file. Older Flutter plugins (like vosk_flutter) only set the package
// attribute in AndroidManifest.xml and have no namespace field in build.gradle.
// plugins.withId fires when the plugin is applied (during evaluation, before
// the android{} DSL block runs), so namespace is still null at that point.
// We read it from the manifest and set it; if the project's own android{}
// block also sets namespace it will simply overwrite ours — no conflict.
subprojects {
    plugins.withId("com.android.library") {
        val android = extensions.getByType<com.android.build.gradle.LibraryExtension>()
        if (android.namespace == null) {
            val manifestFile = file("src/main/AndroidManifest.xml")
            if (manifestFile.exists()) {
                val xml = groovy.xml.XmlParser().parse(manifestFile)
                android.namespace = xml.attribute("package")?.toString() ?: ""
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
