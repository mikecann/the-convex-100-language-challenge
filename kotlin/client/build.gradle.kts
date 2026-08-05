plugins {
    kotlin("jvm") version "2.2.21"
    kotlin("plugin.serialization") version "2.2.21"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    testImplementation(kotlin("test"))
}

kotlin {
    jvmToolchain(21)
}

sourceSets {
    main {
        kotlin.srcDir("src/main/kotlin")
    }
    test {
        kotlin.srcDir("src/test/kotlin")
    }
    create("adapter") {
        kotlin.srcDir("tests/conformance")
        compileClasspath += sourceSets.main.get().output + configurations.runtimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }
    create("example") {
        kotlin.srcDir("../examples/basics")
        compileClasspath += sourceSets.main.get().output + configurations.runtimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }
}

tasks.register<JavaExec>("runAdapter") {
    classpath = sourceSets["adapter"].runtimeClasspath
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
    from(sourceSets.main.get().output)
    from(sourceSets["adapter"].output)
    dependsOn(configurations.runtimeClasspath)
    from({ configurations.runtimeClasspath.get().filter { it.name.endsWith(".jar") }.map { zipTree(it) } })
}

tasks.register<Jar>("exampleJar") {
    archiveFileName.set("convex-kotlin-example.jar")
    manifest { attributes["Main-Class"] = "convex.kotlin.example.MainKt" }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(sourceSets.main.get().output)
    from(sourceSets["example"].output)
    dependsOn(configurations.runtimeClasspath)
    from({ configurations.runtimeClasspath.get().filter { it.name.endsWith(".jar") }.map { zipTree(it) } })
}

tasks.check {
    dependsOn("adapterJar", "exampleJar")
}
