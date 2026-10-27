// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CrowdfundingHitos
/// @notice Plataforma de crowdfunding en la que los fondos NO se entregan de golpe al
///         creador: quedan custodiados por el contrato y se liberan por hitos. Cada hito
///         (salvo el primero) debe ser aprobado por los mecenas mediante una votación
///         ponderada por lo aportado. Si la campaña no alcanza el objetivo, si un hito
///         es rechazado o si el creador abandona el proyecto, los mecenas recuperan la
///         parte proporcional de los fondos que todavía no se han liberado.
/// @dev Técnicas de optimización de gas aplicadas:
///      - Empaquetado de structs (address + uint40 + uint8 + enum en un slot, uint96...).
///      - Struct `Mecenas` en un único slot (aportación + último voto + reembolsado):
///        evita un mapping adicional de "ya ha votado".
///      - Errores personalizados en lugar de mensajes `require` con string.
///      - `constant` para parámetros fijos (no ocupan storage).
///      - `calldata` para el array de importes de los hitos.
///      - `unchecked` en contadores y restas que no pueden desbordar.
///      - Punteros `storage` en vez de copiar structs a memoria.
///      - Patrón pull-payment para el creador y reembolsos individuales.
///      - Evaluación perezosa: la campaña fallida se detecta al reembolsar, sin
///        necesidad de una transacción extra que "cierre" la financiación.
contract CrowdfundingHitos {
    // ------------------------------------------------------------------ Tipos
    enum Estado {
        Financiacion, // 0: recaudando aportaciones
        EnCurso,      // 1: objetivo alcanzado; el creador trabaja en el siguiente hito
        Votacion,     // 2: los mecenas votan si el hito actual se ha cumplido
        Finalizada,   // 3: todos los hitos liberados
        Cancelada,    // 4: hito rechazado, abandono o cancelación del creador
        Fallida       // 5: no se alcanzó el objetivo a tiempo
    }

    struct Campana {
        // slot 0 (28 bytes)
        address creador;
        uint40 fechaLimite;     // fin del periodo de financiación
        uint8 numHitos;
        uint8 hitoActual;       // índice del siguiente hito pendiente de liberar
        Estado estado;
        // slot 1 (29 bytes)
        uint96 objetivo;
        uint96 recaudado;
        uint40 ultimaActividad; // para detectar abandono del creador
        // slot 2 (12 bytes)
        uint96 liberado;        // total ya entregado al creador
    }

    struct Hito {
        // slot 0 (29 bytes)
        uint96 importe;
        uint96 votosFavor;
        uint40 finVotacion;
        // slot 1 (12 bytes)
        uint96 votosContra;
    }

    struct Mecenas {
        // 1 slot (14 bytes)
        uint96 aportacion;
        uint8 votoEnHito;  // índice+1 del último hito votado (0 = nunca)
        bool reembolsado;
    }

    // ------------------------------------------------------------- Parámetros
    uint256 public constant DURACION_VOTACION = 7 days;
    uint256 public constant PLAZO_ABANDONO = 90 days;
    uint256 public constant DURACION_MAX_FINANCIACION = 90 days;
    uint256 public constant QUORUM_PCT = 50; // % de lo recaudado que debe votar
    uint256 public constant MAX_HITOS = 10;

    // ----------------------------------------------------------------- Estado
    uint256 public numCampanas;
    mapping(uint256 => Campana) public campanas;
    mapping(uint256 => mapping(uint256 => Hito)) public hitos;
    mapping(uint256 => mapping(address => Mecenas)) public mecenas;
    mapping(address => uint256) public saldoCreador;

    // ---------------------------------------------------------------- Eventos
    event CampanaCreada(uint256 indexed id, address indexed creador, uint96 objetivo, uint40 fechaLimite, uint8 numHitos);
    event Aportacion(uint256 indexed id, address indexed mecenas, uint96 importe);
    event CampanaFinanciada(uint256 indexed id);
    event VotacionAbierta(uint256 indexed id, uint8 indexed hito, uint40 finVotacion);
    event Voto(uint256 indexed id, uint8 indexed hito, address indexed mecenas, bool aFavor, uint96 peso);
    event HitoLiberado(uint256 indexed id, uint8 indexed hito, uint96 importe);
    event HitoRechazado(uint256 indexed id, uint8 indexed hito);
    event CampanaFinalizada(uint256 indexed id);
    event CampanaCancelada(uint256 indexed id);
    event Reembolso(uint256 indexed id, address indexed mecenas, uint256 importe);
    event Retirada(address indexed creador, uint256 importe);

    // ---------------------------------------------------------------- Errores
    error DatosInvalidos();
    error NoAutorizado();
    error EstadoInvalido(Estado actual);
    error ExcedeObjetivo();
    error PlazoVencido();
    error PlazoNoAlcanzado();
    error NoEsMecenas();
    error YaVotado();
    error SinSaldo();
    error TransferenciaFallida();

    // ================================================================ Creador

    /// @notice Crea una campaña. La suma de los hitos debe ser igual al objetivo.
    /// @param objetivo Importe total a recaudar (wei).
    /// @param duracion Segundos que dura la fase de financiación.
    /// @param importesHitos Importe de cada hito; el primero se libera al financiarse.
    function crearCampana(uint96 objetivo, uint40 duracion, uint96[] calldata importesHitos)
        external
        returns (uint256 id)
    {
        uint256 n = importesHitos.length;
        if (n == 0 || n > MAX_HITOS) revert DatosInvalidos();
        if (duracion == 0 || duracion > DURACION_MAX_FINANCIACION) revert DatosInvalidos();

        unchecked { id = numCampanas++; }

        uint256 suma;
        for (uint256 i; i < n; ) {
            uint96 importe = importesHitos[i];
            if (importe == 0) revert DatosInvalidos();
            suma += importe;
            hitos[id][i].importe = importe;
            unchecked { ++i; }
        }
        if (suma != objetivo) revert DatosInvalidos();

        Campana storage c = campanas[id];
        c.creador = msg.sender;
        c.fechaLimite = uint40(block.timestamp + duracion);
        c.numHitos = uint8(n);
        c.objetivo = objetivo;
        // estado = Financiacion (0, valor por defecto): no se escribe

        emit CampanaCreada(id, msg.sender, objetivo, c.fechaLimite, uint8(n));
    }

    /// @notice El creador pide que se vote la liberación del siguiente hito.
    function solicitarHito(uint256 id) external {
        Campana storage c = campanas[id];
        if (msg.sender != c.creador) revert NoAutorizado();
        _exigirEstado(c, Estado.EnCurso);

        uint8 h = c.hitoActual;
        uint40 fin = uint40(block.timestamp + DURACION_VOTACION);
        hitos[id][h].finVotacion = fin;
        c.estado = Estado.Votacion;
        c.ultimaActividad = uint40(block.timestamp);
        emit VotacionAbierta(id, h, fin);
    }

    /// @notice El creador renuncia al proyecto; los mecenas recuperan lo no liberado.
    function cancelarCampana(uint256 id) external {
        Campana storage c = campanas[id];
        if (msg.sender != c.creador) revert NoAutorizado();
        Estado e = c.estado;
        if (e != Estado.Financiacion && e != Estado.EnCurso) revert EstadoInvalido(e);
        _cancelar(id, c);
    }

    /// @notice Retira los fondos de hitos liberados (pull payment).
    function retirar() external {
        uint256 importe = saldoCreador[msg.sender];
        if (importe == 0) revert SinSaldo();
        saldoCreador[msg.sender] = 0; // checks-effects-interactions
        (bool ok, ) = payable(msg.sender).call{value: importe}("");
        if (!ok) revert TransferenciaFallida();
        emit Retirada(msg.sender, importe);
    }

    // ================================================================ Mecenas

    /// @notice Aporta fondos a una campaña en fase de financiación.
    function aportar(uint256 id) external payable {
        Campana storage c = campanas[id];
        _exigirEstado(c, Estado.Financiacion);
        if (msg.sender == c.creador) revert NoAutorizado(); // evita autovotarse
        if (block.timestamp > c.fechaLimite) revert PlazoVencido();
        if (msg.value == 0) revert DatosInvalidos();

        uint256 nuevo = uint256(c.recaudado) + msg.value;
        if (nuevo > c.objetivo) revert ExcedeObjetivo();

        // nuevo <= objetivo (uint96) => los casts son seguros
        mecenas[id][msg.sender].aportacion += uint96(msg.value);
        c.recaudado = uint96(nuevo);
        emit Aportacion(id, msg.sender, uint96(msg.value));

        if (nuevo == c.objetivo) {
            emit CampanaFinanciada(id);
            _liberarHito(id, c); // el primer hito se entrega al financiarse
        }
    }

    /// @notice Vota si el hito actual se ha cumplido. El voto pesa lo aportado.
    function votar(uint256 id, bool aFavor) external {
        Campana storage c = campanas[id];
        _exigirEstado(c, Estado.Votacion);

        uint8 h = c.hitoActual;
        Hito storage hito = hitos[id][h];
        if (block.timestamp > hito.finVotacion) revert PlazoVencido();

        Mecenas storage m = mecenas[id][msg.sender];
        uint96 peso = m.aportacion;
        if (peso == 0) revert NoEsMecenas();
        unchecked {
            if (m.votoEnHito == h + 1) revert YaVotado();
            m.votoEnHito = h + 1; // h < MAX_HITOS: no desborda
        }

        uint256 recaudado = c.recaudado;
        emit Voto(id, h, msg.sender, aFavor, peso);

        // La suma de votos nunca supera `recaudado` (uint96): no desborda.
        if (aFavor) {
            uint96 favor;
            unchecked { favor = hito.votosFavor + peso; }
            hito.votosFavor = favor;
            // Resolución anticipada: mayoría absoluta de los fondos a favor.
            if (uint256(favor) * 2 > recaudado) _liberarHito(id, c);
        } else {
            uint96 contra;
            unchecked { contra = hito.votosContra + peso; }
            hito.votosContra = contra;
            // La mitad o más en contra: ya no puede aprobarse.
            if (uint256(contra) * 2 >= recaudado) _rechazarHito(id, c, h);
        }
    }

    /// @notice Recupera la parte proporcional de los fondos no liberados.
    ///         Válido si la campaña falló (objetivo no alcanzado) o fue cancelada.
    function reembolsar(uint256 id) external {
        Campana storage c = campanas[id];
        Estado e = c.estado;
        if (e == Estado.Financiacion && block.timestamp > c.fechaLimite) {
            c.estado = Estado.Fallida; // evaluación perezosa
            e = Estado.Fallida;
        }
        if (e != Estado.Fallida && e != Estado.Cancelada) revert EstadoInvalido(e);

        Mecenas storage m = mecenas[id][msg.sender];
        uint256 aportado = m.aportacion;
        if (aportado == 0 || m.reembolsado) revert SinSaldo();
        m.reembolsado = true;

        uint256 recaudado = c.recaudado; // > 0 porque aportado > 0
        uint256 importe;
        unchecked { importe = aportado * (recaudado - c.liberado) / recaudado; }

        if (importe != 0) {
            (bool ok, ) = payable(msg.sender).call{value: importe}("");
            if (!ok) revert TransferenciaFallida();
        }
        emit Reembolso(id, msg.sender, importe);
    }

    // ============================================================ Cualquiera

    /// @notice Cierra una votación cuyo plazo terminó sin resolución anticipada.
    ///         Se aprueba si votó al menos QUORUM_PCT % de lo recaudado y hay más
    ///         votos a favor que en contra.
    function cerrarVotacion(uint256 id) external {
        Campana storage c = campanas[id];
        _exigirEstado(c, Estado.Votacion);
        uint8 h = c.hitoActual;
        Hito storage hito = hitos[id][h];
        if (block.timestamp <= hito.finVotacion) revert PlazoNoAlcanzado();

        uint256 favor = hito.votosFavor;
        uint256 contra = hito.votosContra;
        bool quorum = (favor + contra) * 100 >= uint256(c.recaudado) * QUORUM_PCT;

        if (quorum && favor > contra) _liberarHito(id, c);
        else _rechazarHito(id, c, h);
    }

    /// @notice Si el creador lleva PLAZO_ABANDONO sin solicitar el siguiente hito,
    ///         cualquiera puede cancelar la campaña para que los mecenas recuperen fondos.
    function declararAbandono(uint256 id) external {
        Campana storage c = campanas[id];
        _exigirEstado(c, Estado.EnCurso);
        if (block.timestamp <= uint256(c.ultimaActividad) + PLAZO_ABANDONO) revert PlazoNoAlcanzado();
        _cancelar(id, c);
    }

    // ================================================================= Vistas

    /// @notice Importe que un mecenas recibiría si reembolsara ahora.
    function reembolsoDisponible(uint256 id, address cuenta) external view returns (uint256) {
        Campana storage c = campanas[id];
        Mecenas storage m = mecenas[id][cuenta];
        if (m.aportacion == 0 || m.reembolsado) return 0;
        Estado e = c.estado;
        bool fallida = e == Estado.Financiacion && block.timestamp > c.fechaLimite;
        if (!fallida && e != Estado.Fallida && e != Estado.Cancelada) return 0;
        return uint256(m.aportacion) * (c.recaudado - c.liberado) / c.recaudado;
    }

    // ============================================================== Internas

    function _exigirEstado(Campana storage c, Estado esperado) private view {
        Estado actual = c.estado;
        if (actual != esperado) revert EstadoInvalido(actual);
    }

    function _liberarHito(uint256 id, Campana storage c) private {
        uint8 h = c.hitoActual;
        uint96 importe = hitos[id][h].importe;
        unchecked {
            c.liberado += importe;          // suma de hitos == objetivo
            saldoCreador[c.creador] += importe;
            c.hitoActual = h + 1;
        }
        c.ultimaActividad = uint40(block.timestamp);
        emit HitoLiberado(id, h, importe);

        if (h + 1 == c.numHitos) {
            c.estado = Estado.Finalizada;
            emit CampanaFinalizada(id);
        } else {
            c.estado = Estado.EnCurso;
        }
    }

    function _rechazarHito(uint256 id, Campana storage c, uint8 h) private {
        emit HitoRechazado(id, h);
        _cancelar(id, c);
    }

    function _cancelar(uint256 id, Campana storage c) private {
        c.estado = Estado.Cancelada;
        emit CampanaCancelada(id);
    }
}
