// Copyright (c) 2026 Viva Republica, Inc.

package im.toss.necto.model

/**
 * Semantic version used to compare plugin `version` values. Prerelease and build
 * metadata are parsed but ignored when ordering.
 */
public data class NectoSemanticVersion(
    val major: Int,
    val minor: Int,
    val patch: Int,
    val prerelease: String? = null,
    val build: String? = null,
) : Comparable<NectoSemanticVersion> {

    override fun compareTo(other: NectoSemanticVersion): Int =
        compareValuesBy(this, other, { it.major }, { it.minor }, { it.patch })

    override fun toString(): String = buildString {
        append("$major.$minor.$patch")
        prerelease?.let { append("-$it") }
        build?.let { append("+$it") }
    }

    public companion object {
        /** Parses `MAJOR.MINOR.PATCH[-prerelease][+build]`, or returns null. */
        public fun parse(text: String): NectoSemanticVersion? {
            var body = text

            var build: String? = null
            val plus = body.indexOf('+')
            if (plus >= 0) {
                build = body.substring(plus + 1)
                body = body.substring(0, plus)
                if (build.isEmpty()) return null
            }

            var prerelease: String? = null
            val dash = body.indexOf('-')
            if (dash >= 0) {
                prerelease = body.substring(dash + 1)
                body = body.substring(0, dash)
                if (prerelease.isEmpty()) return null
            }

            val parts = body.split('.')
            if (parts.size != 3) return null
            val numbers = parts.map { part ->
                if (part.isEmpty() || !part.all { it in '0'..'9' }) return null
                if (part.length > 1 && part[0] == '0') return null
                part.toIntOrNull() ?: return null
            }
            return NectoSemanticVersion(numbers[0], numbers[1], numbers[2], prerelease, build)
        }
    }
}
