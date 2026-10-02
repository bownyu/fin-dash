package com.findash.fin_dash
import org.junit.Assert.*
import org.junit.Test

class OtaPolicyTest {
    @Test fun matchingPackageAndSignerAcceptOnlyNewBuild() {
        OtaPolicy.validate("com.findash.fin_dash", "com.findash.fin_dash", 4, 5, 5, setOf("signer"), setOf("signer"))
    }
    @Test fun wrongPackageCannotReplaceApplication() {
        assertThrows(IllegalArgumentException::class.java) {
            OtaPolicy.validate("com.findash.fin_dash", "other.app", 4, 5, 5, setOf("signer"), setOf("signer"))
        }
    }
    @Test fun downgradeAndWrongExpectedVersionAreRejected() {
        for (build in listOf(3L, 4L, 6L)) assertThrows(IllegalArgumentException::class.java) {
            OtaPolicy.validate("com.findash.fin_dash", "com.findash.fin_dash", 4, build, 5, setOf("signer"), setOf("signer"))
        }
    }
    @Test fun differentAndEmptySigningCertificatesAreRejected() {
        for (signers in listOf(setOf("other"), emptySet())) assertThrows(IllegalArgumentException::class.java) {
            OtaPolicy.validate("com.findash.fin_dash", "com.findash.fin_dash", 4, 5, 5, setOf("signer"), signers)
        }
    }
}
