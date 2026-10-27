// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "remix_tests.sol";
import "../contracts/CrowdfundingHitos.sol";

// Pruebas unitarias para el plugin "Solidity Unit Testing" de Remix.
//
// Cada persona (creador y mecenas) es un contrato Participante con su propia
// dirección y saldo. Participante no tiene funciones propias (Remix no las permite
// con parámetros en este fichero): solo reenvía al contrato la llamada que recibe.
//
// Antes de cada prueba se crea una campaña de 3000 wei en 3 hitos de 1000.
// Mecenas: Ana aporta 1500 (50 %), Beto 1000 (33 %) y Carla 500 (17 %).

contract Participante {
    // Recibe reembolsos y retiradas
    receive() external payable {}

    // Recibe (destino, llamada) y la ejecuta con el ETH recibido
    fallback() external payable {
        (address destino, bytes memory llamada) = abi.decode(msg.data, (address, bytes));
        (bool ok, ) = destino.call{value: msg.value}(llamada);
        require(ok);
    }
}

contract CrowdfundingHitosTest {
    CrowdfundingHitos cf;
    Participante creador;
    Participante ana;
    Participante beto;
    Participante carla;
    uint256 id; // campaña de cada prueba

    function beforeAll() public {
        cf = new CrowdfundingHitos();
    }

    function beforeEach() public {
        creador = new Participante();
        ana = new Participante();
        beto = new Participante();
        carla = new Participante();
        _hace(creador, 0, abi.encodeCall(cf.crearCampana, (3000, 1 days, _hitos(1000))));
        id = cf.numCampanas() - 1;
    }

    // ----------------------------------------------------------- creación

    function testCampanaCreada() public {
        (address c, , uint8 numHitos, , CrowdfundingHitos.Estado e, uint96 objetivo, , , ) = cf.campanas(id);
        Assert.equal(c, address(creador), "Creador correcto");
        Assert.equal(uint256(numHitos), 3, "Tiene 3 hitos");
        Assert.equal(uint256(objetivo), 3000, "Objetivo de 3000");
        Assert.equal(uint256(e), 0, "Empieza en Financiacion");
    }

    function testHitosQueNoSumanElObjetivo() public {
        bool ok = _hace(creador, 0, abi.encodeCall(cf.crearCampana, (3000, 1 days, _hitos(900))));
        Assert.ok(!ok, "Revierte si los hitos no suman el objetivo");
    }

    // ------------------------------------------------------- financiación

    /// #value: 3000
    function testFinanciarLiberaPrimerHito() public payable {
        _financiar();
        Assert.equal(_estado(), 1, "Pasa a EnCurso");
        Assert.equal(cf.saldoCreador(address(creador)), 1000, "Libera el primer hito");
    }

    /// #value: 4000
    function testNoSeSuperaElObjetivo() public payable {
        _hace(ana, 2500, abi.encodeCall(cf.aportar, (id)));
        bool ok = _hace(beto, 1000, abi.encodeCall(cf.aportar, (id)));
        Assert.ok(!ok, "No se puede aportar por encima del objetivo");
    }

    /// #value: 100
    function testCreadorNoPuedeAportar() public payable {
        bool ok = _hace(creador, 100, abi.encodeCall(cf.aportar, (id)));
        Assert.ok(!ok, "El creador no puede aportar a su campana");
    }

    // ----------------------------------------------------------- votación

    /// #value: 3000
    function testAprobarHitoYRetirar() public payable {
        _financiar();
        _hace(creador, 0, abi.encodeCall(cf.solicitarHito, (id)));
        Assert.equal(_estado(), 2, "Pasa a Votacion");

        _hace(ana, 0, abi.encodeCall(cf.votar, (id, true)));  // 50 %: aun no es mayoria
        _hace(beto, 0, abi.encodeCall(cf.votar, (id, true))); // 83 %: aprobado
        Assert.equal(_estado(), 1, "Vuelve a EnCurso");

        _hace(creador, 0, abi.encodeCall(cf.retirar, ()));
        Assert.equal(address(creador).balance, 2000, "El creador cobra 2 hitos");
    }

    /// #value: 3000
    function testNoSePuedeVotarDosVeces() public payable {
        _financiar();
        _hace(creador, 0, abi.encodeCall(cf.solicitarHito, (id)));
        _hace(carla, 0, abi.encodeCall(cf.votar, (id, true)));
        bool ok = _hace(carla, 0, abi.encodeCall(cf.votar, (id, true)));
        Assert.ok(!ok, "Solo un voto por hito");
    }

    // ----------------------------------------------------------- reembolso

    /// #value: 3000
    function testRechazarHitoYReembolsar() public payable {
        _financiar();
        _hace(creador, 0, abi.encodeCall(cf.solicitarHito, (id)));
        _hace(ana, 0, abi.encodeCall(cf.votar, (id, false))); // 50 % en contra: rechazado
        Assert.equal(_estado(), 4, "Campana Cancelada");

        // Quedan 2000 sin liberar, repartidos segun lo aportado
        _hace(ana, 0, abi.encodeCall(cf.reembolsar, (id)));
        _hace(beto, 0, abi.encodeCall(cf.reembolsar, (id)));
        _hace(carla, 0, abi.encodeCall(cf.reembolsar, (id)));
        Assert.equal(address(ana).balance, 1000, "Ana: 1500 * 2000 / 3000");
        Assert.equal(address(beto).balance, 666, "Beto: 1000 * 2000 / 3000");
        Assert.equal(address(carla).balance, 333, "Carla: 500 * 2000 / 3000");
    }

    // ----------------------------------------------------- flujo completo

    /// #value: 3000
    function testFlujoCompleto() public payable {
        _financiar();
        for (uint256 i = 0; i < 2; i++) {
            _hace(creador, 0, abi.encodeCall(cf.solicitarHito, (id)));
            _hace(ana, 0, abi.encodeCall(cf.votar, (id, true)));
            _hace(beto, 0, abi.encodeCall(cf.votar, (id, true)));
        }
        Assert.equal(_estado(), 3, "Campana Finalizada");
        _hace(creador, 0, abi.encodeCall(cf.retirar, ()));
        Assert.equal(address(creador).balance, 3000, "El creador cobra los 3000");
    }

    // --------------------------------------------- utilidades (internas)

    /// Hace que `p` llame al contrato con `llamada` y `valor` wei. Devuelve si tuvo éxito.
    function _hace(Participante p, uint256 valor, bytes memory llamada) internal returns (bool ok) {
        (ok, ) = address(p).call{value: valor}(abi.encode(address(cf), llamada));
    }

    function _hitos(uint96 ultimo) internal pure returns (uint96[] memory h) {
        h = new uint96[](3);
        h[0] = 1000;
        h[1] = 1000;
        h[2] = ultimo;
    }

    function _financiar() internal {
        _hace(ana, 1500, abi.encodeCall(cf.aportar, (id)));
        _hace(beto, 1000, abi.encodeCall(cf.aportar, (id)));
        _hace(carla, 500, abi.encodeCall(cf.aportar, (id)));
    }

    function _estado() internal view returns (uint256) {
        (, , , , CrowdfundingHitos.Estado e, , , , ) = cf.campanas(id);
        return uint256(e);
    }
}
