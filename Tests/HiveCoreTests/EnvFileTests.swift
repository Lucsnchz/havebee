import Foundation
import Testing
@testable import HiveCore

@Suite("Archivos .env")
struct EnvFileTests {
    let laravel = """
    # Aplicación
    APP_NAME="Emplag v2"
    APP_ENV=local
    APP_URL=https://emplag-v2.test # el sitio de Herd

    SESSION_DOMAIN=.emplag-v2.test
    SANCTUM_STATEFUL_DOMAINS="emplag-v2.test,localhost:5173,miemplag-v2.test"
    VITE_APP_URL="${APP_URL}"
    MAIL_FROM_ADDRESS=hola@emplag-v2.test

    """

    @Test("Lee valores con y sin comillas, con comentarios y export")
    func values() {
        #expect(EnvFile.value("APP_NAME", in: laravel) == "Emplag v2")
        #expect(EnvFile.value("APP_URL", in: laravel) == "https://emplag-v2.test")
        #expect(EnvFile.value("NO_ESTA", in: laravel) == nil)
        #expect(EnvFile.value("A", in: "export A='con # adentro' # comentario") == "con # adentro")
        #expect(EnvFile.value("B", in: "  B = espacios  ") == "espacios")
        #expect(EnvFile.value("C", in: "# C=comentada") == nil)
    }

    @Test("Cambia un valor conservando comillas, comentario y el resto del archivo")
    func setKeepsFormat() {
        let updated = EnvFile.set("APP_URL", value: "https://emplag-v2-telefonos.test", in: laravel)
        #expect(updated.contains("APP_URL=https://emplag-v2-telefonos.test # el sitio de Herd\n"))
        #expect(updated.replacingOccurrences(of: "https://emplag-v2-telefonos.test #", with: "https://emplag-v2.test #") == laravel)
        let quoted = EnvFile.set("APP_NAME", value: "Otro", in: laravel)
        #expect(quoted.contains("APP_NAME=\"Otro\"\n"))
        let single = EnvFile.set("A", value: "b", in: "export A='a' # x\r\nZ=1\r\n")
        #expect(single == "export A='b' # x\r\nZ=1\r\n")
    }

    @Test("Una clave que no está se agrega al final; con espacios va entre comillas")
    func setAppends() {
        #expect(EnvFile.set("APP_URL", value: "http://x.test", in: "A=1\n") == "A=1\nAPP_URL=http://x.test\n")
        #expect(EnvFile.set("APP_URL", value: "http://x.test", in: "A=1") == "A=1\nAPP_URL=http://x.test\n")
        #expect(EnvFile.set("APP_NAME", value: "Mi app", in: "") == "APP_NAME=\"Mi app\"\n")
        #expect(EnvFile.set("APP_NAME", value: "Mi app", in: "APP_NAME=viejo\n") == "APP_NAME=\"Mi app\"\n")
    }

    @Test("Cambia el host solo en SESSION_DOMAIN y SANCTUM_STATEFUL_DOMAINS, y como palabra entera")
    func replaceHost() {
        let updated = EnvFile.replaceHost(old: "emplag-v2.test", new: "emplag-v2-x.test", in: laravel)
        #expect(EnvFile.value("SESSION_DOMAIN", in: updated) == ".emplag-v2-x.test")
        #expect(EnvFile.value("SANCTUM_STATEFUL_DOMAINS", in: updated) == "emplag-v2-x.test,localhost:5173,miemplag-v2.test")
        #expect(updated.contains("SANCTUM_STATEFUL_DOMAINS=\"emplag-v2-x.test,"))
        #expect(EnvFile.value("MAIL_FROM_ADDRESS", in: updated) == "hola@emplag-v2.test") // otras claves no se tocan
        #expect(EnvFile.replaceHost(old: "", new: "x", in: laravel) == laravel)
    }

    @Test("APP_URL nuevo y los dominios que dependían del viejo")
    func rewriteAppURL() {
        let updated = EnvFile.rewriteAppURL("http://emplag-v2-telefonos.test", in: laravel)
        #expect(EnvFile.value("APP_URL", in: updated) == "http://emplag-v2-telefonos.test")
        #expect(EnvFile.value("SESSION_DOMAIN", in: updated) == ".emplag-v2-telefonos.test")
        #expect(EnvFile.value("VITE_APP_URL", in: updated) == "${APP_URL}")
        #expect(EnvFile.host(of: "https://app.test:8000/x") == "app.test")
        #expect(EnvFile.host(of: "nada") == nil)
        // Sin APP_URL previo, solo la agrega.
        #expect(EnvFile.rewriteAppURL("http://a.test", in: "SESSION_DOMAIN=b.test\n") == "SESSION_DOMAIN=b.test\nAPP_URL=http://a.test\n")
    }
}
