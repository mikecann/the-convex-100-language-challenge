plugins {
    kotlin("jvm") version "2.2.21"
    kotlin("plugin.serialization") version "2.2.21"
    id("org.jlleitschuh.gradle.ktlint") version "14.2.0"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    testImplementation(kotlin("test-junit5"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:1.13.4")
}

kotlin {
    jvmToolchain(21)
}

val adapterSourceSet =
    sourceSets.create("adapter") {
        kotlin.setSrcDirs(listOf("src/main/kotlin", "tests/conformance"))
        kotlin.exclude("**/*Test.kt")
        compileClasspath += configurations.runtimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }

val adapterTestSourceSet =
    sourceSets.create("adapterTest") {
        kotlin.setSrcDirs(listOf("tests/conformance", "tests/fixtures"))
        kotlin.include("**/*Test.kt", "**/*Fixture.kt")
        compileClasspath += adapterSourceSet.output + configurations.testRuntimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }

sourceSets {
    main {
        kotlin.srcDir("src/main/kotlin")
    }
    test {
        kotlin.setSrcDirs(listOf("src/test/kotlin", "tests/fixtures"))
    }
    create("example") {
        kotlin.srcDir("../examples/basics")
        compileClasspath += sourceSets.main.get().output + configurations.runtimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }
}

tasks.register<JavaExec>("runAdapter") {
    classpath = adapterSourceSet.runtimeClasspath
    mainClass.set("convex.kotlin.adapter.AdapterMainKt")
}

tasks.register<JavaExec>("runExample") {
    classpath = sourceSets["example"].runtimeClasspath
    mainClass.set("convex.kotlin.example.MainKt")
}

tasks.register<Jar>("adapterJar") {
    archiveFileName.set("convex-kotlin-adapter.jar")
    manifest { attributes["Main-Class"] = "convex.kotlin.adapter.AdapterMainKt" }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(adapterSourceSet.output)
    dependsOn(configurations.runtimeClasspath)
    from({
        configurations.runtimeClasspath
            .get()
            .filter { it.name.endsWith(".jar") }
            .map { zipTree(it) }
    })
}

tasks.register<Jar>("exampleJar") {
    archiveFileName.set("convex-kotlin-example.jar")
    manifest { attributes["Main-Class"] = "convex.kotlin.example.MainKt" }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(sourceSets.main.get().output)
    from(sourceSets["example"].output)
    dependsOn(configurations.runtimeClasspath)
    from({
        configurations.runtimeClasspath
            .get()
            .filter { it.name.endsWith(".jar") }
            .map { zipTree(it) }
    })
}

tasks.check {
    dependsOn("adapterJar", "adapterTest", "exampleJar")
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
}

tasks.register<Test>("adapterTest") {
    testClassesDirs = adapterTestSourceSet.output.classesDirs
    classpath = adapterTestSourceSet.runtimeClasspath
}

ktlint {
    version.set("1.7.1")
}
