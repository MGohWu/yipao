package org.yipao.app.ui.components

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CarModelResourceFilesTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun servesEntryAndNestedAssetsThroughRootAlias() {
        val actual = temporary.newFolder("actual")
        val alias = File(temporary.root, "alias")
        Files.createSymbolicLink(alias.toPath(), actual.toPath())
        val entry = File(actual, "index.html").apply { writeText("model") }
        val asset = File(actual, "Lafa5_2026/model.fbx").apply {
            parentFile?.mkdirs()
            writeBytes(byteArrayOf(1, 2, 3))
        }

        val resources = CarModelResourceFiles(alias)

        assertEquals(entry.canonicalFile, resources.resolve("index.html"))
        assertEquals(asset.canonicalFile, resources.resolve("Lafa5_2026/model.fbx"))
    }

    @Test
    fun servesFilesFromUnnormalizedRoot() {
        val root = temporary.newFolder("model")
        val entry = File(root, "index.html").apply { writeText("model") }
        val resources = CarModelResourceFiles(File(root, "../model"))

        assertEquals(entry.canonicalFile, resources.resolve("index.html"))
    }

    @Test
    fun rejectsTraversalAndSiblingWithSamePrefix() {
        val root = temporary.newFolder("model")
        val sibling = temporary.newFolder("model-other")
        File(sibling, "secret.txt").writeText("outside")
        val resources = CarModelResourceFiles(root)

        assertNull(resources.resolve("../model-other/secret.txt"))
        assertNull(resources.resolve("nested/../../model-other/secret.txt"))
    }

    @Test
    fun rejectsSymlinkEscapingRoot() {
        val root = temporary.newFolder("model")
        val outside = temporary.newFile("outside.txt")
        Files.createSymbolicLink(File(root, "escape.txt").toPath(), outside.toPath())

        assertNull(CarModelResourceFiles(root).resolve("escape.txt"))
    }

    @Test
    fun rejectsMissingFilesAndDirectories() {
        val root = temporary.newFolder("model")
        File(root, "textures").mkdirs()
        val resources = CarModelResourceFiles(root)

        assertNull(resources.resolve("missing.fbx"))
        assertNull(resources.resolve("textures"))
        assertNull(resources.resolve(""))
    }
}
