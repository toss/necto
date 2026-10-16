// Copyright (c) 2026 Viva Republica, Inc.

import groovy.json.JsonSlurper
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import java.io.File

/**
 * Packages built web panels as Java resources under [root]/<id>, each with a files.txt
 * index, because resource folders cannot be listed at run time (an APK is not a
 * directory).
 *
 * Panels are read from the repository's built output, so Android carries the same panel
 * code as iOS. A manifest in [manifests] named <id>.json replaces the panel's own, for
 * wording that differs on Android; it must declare the same operations, so a contract
 * cannot drift from the panel it rides with.
 */
abstract class NectoPanelResources : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val panels: DirectoryProperty

    @get:Input
    abstract val ids: ListProperty<String>

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    @get:Optional
    abstract val manifests: DirectoryProperty

    @get:Input
    abstract val root: Property<String>

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun generate() {
        val destinationRoot = output.get().asFile.resolve(root.get())
        output.get().asFile.deleteRecursively()
        for (id in ids.get()) {
            val panel = panels.get().asFile.resolve(id)
            if (!panel.resolve("manifest.json").isFile) throw GradleException("No built panel at $panel")
            val destination = destinationRoot.resolve(id)
            val paths = panel.walkTopDown()
                .filter { it.isFile && !it.name.startsWith(".") }
                .map { it.relativeTo(panel).invariantSeparatorsPath }
                .sorted()
                .toList()
            paths.forEach { path -> panel.resolve(path).copyTo(destination.resolve(path)) }
            manifests.orNull?.asFile?.resolve("$id.json")?.takeIf { it.isFile }?.let { override ->
                if (contract(override) != contract(panel.resolve("manifest.json"))) {
                    throw GradleException("$override must declare the same operations as $panel/manifest.json")
                }
                override.copyTo(destination.resolve("manifest.json"), overwrite = true)
            }
            destination.resolve("files.txt").writeText(paths.joinToString("\n", postfix = "\n"))
        }
    }

    /** Which operations a manifest declares and how they bind; wording and schemas may differ. */
    private fun contract(manifest: File): List<Any?> {
        @Suppress("UNCHECKED_CAST")
        val json = JsonSlurper().parse(manifest) as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val operations = (json["operations"] as List<Map<String, Any?>>)
            .map { listOf(it["id"], it["kind"], it["binding"], it["timeoutMs"]) }
        return listOf(json["schemaVersion"], json["id"], json["version"], json["assets"], json["allowedOrigins"], operations)
    }
}
