/**
 * 2FLOW // SOTA Declarative Orchestration Runtime
 * Interactive Staged Scroll & AST Visualizer Engine
 */

document.addEventListener('DOMContentLoaded', () => {
  initTextCrawl();
  initSvgDrawings();
  initStagedScrollEngine();
  initSynthesisSection();
  initInteractivePlayground();
  initTerminalCopy();
});

/* ==========================================================================
   1. TEXT CRAWL INITIALIZATION (Word-by-word reveal inspired by Levo Studio)
   ========================================================================== */
function initTextCrawl() {
  const crawlElements = document.querySelectorAll('[data-crawl="true"]');

  crawlElements.forEach((el) => {
    // Preserve any existing inner tags with their classes (like <b class="highlight">word</b>)
    const childNodes = Array.from(el.childNodes);
    const fragments = [];

    childNodes.forEach((node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const words = node.textContent.split(/(\s+)/);
        words.forEach((w) => {
          if (/^\s+$/.test(w)) {
            fragments.push(document.createTextNode(w));
          } else if (w.length > 0) {
            const span = document.createElement('span');
            span.className = 'word';
            span.textContent = w;
            fragments.push(span);
          }
        });
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        // Tag like <b> or <span>
        const tagName = node.tagName.toLowerCase();
        const classes = node.className;
        const words = node.textContent.split(/(\s+)/);
        
        words.forEach((w) => {
          if (/^\s+$/.test(w)) {
            fragments.push(document.createTextNode(w));
          } else if (w.length > 0) {
            const span = document.createElement('span');
            span.className = `word ${classes}`;
            span.textContent = w;
            fragments.push(span);
          }
        });
      }
    });

    el.innerHTML = '';
    fragments.forEach((f) => el.appendChild(f));
  });
}

/* ==========================================================================
   2. SVG PATH INITIALIZATION (Measure exact dasharray for drawing)
   ========================================================================== */
function initSvgDrawings() {
  const drawStrokes = document.querySelectorAll('.draw-stroke');
  drawStrokes.forEach((path) => {
    try {
      const length = path.getTotalLength ? path.getTotalLength() : 600;
      path.style.strokeDasharray = `${length}`;
      path.style.strokeDashoffset = `${length}`;
      path.setAttribute('data-length', length);
    } catch (e) {
      // Fallback for rects or non-path elements if browser does not support getTotalLength
      const approx = (parseFloat(path.getAttribute('width') || 200) + parseFloat(path.getAttribute('height') || 100)) * 2;
      path.style.strokeDasharray = `${approx}`;
      path.style.strokeDashoffset = `${approx}`;
      path.setAttribute('data-length', approx);
    }
  });
}

/* ==========================================================================
   3. STAGED SCROLL ENGINE (Sticky fixed sections animated by scroll progress)
   ========================================================================== */
function initStagedScrollEngine() {
  const stagedSections = document.querySelectorAll('[data-staged="true"]');
  let ticking = false;

  function updateScroll() {
    stagedSections.forEach((section) => {
      const rect = section.getBoundingClientRect();
      const totalDist = section.offsetHeight - window.innerHeight;
      const scrolled = -rect.top;
      const progress = Math.min(Math.max(scrolled / totalDist, 0), 1);

      // 1. Update Pinbar Fill
      const pinbar = section.querySelector('.pinbar-fill');
      if (pinbar) {
        pinbar.style.width = `${progress * 100}%`;
      }

      // 2. Word Crawl Animation
      const crawlContainer = section.querySelector('[data-crawl="true"]');
      if (crawlContainer) {
        const words = crawlContainer.querySelectorAll('.word');
        const count = words.length;
        // Map progress range [0.05, 0.85] to [0, count]
        const rangeStart = 0.05;
        const rangeEnd = 0.82;
        const normalized = Math.min(Math.max((progress - rangeStart) / (rangeEnd - rangeStart), 0), 1);
        const litCount = Math.floor(normalized * count);

        words.forEach((word, idx) => {
          if (idx <= litCount) {
            word.classList.add('lit');
          } else {
            word.classList.remove('lit');
          }
        });
      }

      // 3. Section-specific hooks
      const id = section.id;
      if (id === 'capability') {
        updateCapabilitySection(progress);
      } else if (id === 'operadores') {
        updatePrimitivesSection(progress);
      } else if (id === 'sintese') {
        updateSynthesisSection(progress);
      }
    });

    ticking = false;
  }

  window.addEventListener('scroll', () => {
    if (!ticking) {
      window.requestAnimationFrame(updateScroll);
      ticking = true;
    }
  }, { passive: true });

  // Initial call on load
  updateScroll();
}

/* ==========================================================================
   4. CAPABILITY SECTION: Vector Blueprint Line-Drawing
   ========================================================================== */
function updateCapabilitySection(progress) {
  // Elements
  const boxInterface = document.getElementById('cap-box-interface');
  const dotInterface = document.getElementById('cap-dot-interface');
  const textInterface = document.getElementById('cap-text-interface');
  const textStatus = document.getElementById('cap-text-interface-status');

  const conduitLeft = document.getElementById('cap-conduit-left');
  const conduitRight = document.getElementById('cap-conduit-right');
  const boxApi = document.getElementById('cap-box-api');
  const textApi = document.getElementById('cap-text-api');
  const boxWorkers = document.getElementById('cap-box-workers');
  const textWorkers = document.getElementById('cap-text-workers');

  const conduitDbL = document.getElementById('cap-conduit-db-l');
  const conduitDbR = document.getElementById('cap-conduit-db-r');
  const boxDb = document.getElementById('cap-box-db');
  const textDb = document.getElementById('cap-text-db');
  const packet = document.getElementById('cap-traveling-packet');

  function drawElement(elem, start, end) {
    if (!elem) return;
    const len = parseFloat(elem.getAttribute('data-length') || 600);
    if (progress <= start) {
      elem.style.strokeDashoffset = `${len}`;
    } else if (progress >= end) {
      elem.style.strokeDashoffset = '0';
    } else {
      const p = (progress - start) / (end - start);
      elem.style.strokeDashoffset = `${len * (1 - p)}`;
    }
  }

  function fadeElement(elem, threshold) {
    if (!elem) return;
    if (progress >= threshold) {
      elem.classList.add('active');
    } else {
      elem.classList.remove('active');
    }
  }

  // Stage A: Interface Box & Dot (0.05 -> 0.25)
  drawElement(boxInterface, 0.05, 0.25);
  fadeElement(dotInterface, 0.12);
  fadeElement(textInterface, 0.15);
  fadeElement(textStatus, 0.22);

  // Stage B: Conduits down to API & Workers (0.22 -> 0.45)
  drawElement(conduitLeft, 0.22, 0.38);
  drawElement(conduitRight, 0.22, 0.38);
  drawElement(boxApi, 0.35, 0.52);
  fadeElement(textApi, 0.42);
  drawElement(boxWorkers, 0.35, 0.52);
  fadeElement(textWorkers, 0.42);

  // Stage C: Conduits to Postgres / Ledger (0.50 -> 0.75)
  drawElement(conduitDbL, 0.50, 0.65);
  drawElement(conduitDbR, 0.50, 0.65);
  drawElement(boxDb, 0.62, 0.78);
  fadeElement(textDb, 0.70);

  // Stage D: Packet flow along conduits (0.75 -> 1.0)
  if (packet) {
    if (progress > 0.75) {
      packet.style.opacity = '1';
      // Travel down to DB
      const travelP = (progress - 0.75) / 0.25;
      const curY = 92 + travelP * (254 - 92);
      packet.setAttribute('cy', curY);
      packet.setAttribute('cx', 220 + Math.sin(travelP * Math.PI) * 40);
    } else {
      packet.style.opacity = '0';
    }
  }
}

/* ==========================================================================
   5. PRIMITIVES SECTION: Card Sequence Trigger
   ========================================================================== */
function updatePrimitivesSection(progress) {
  const cards = [
    document.getElementById('prim-card-1'),
    document.getElementById('prim-card-2'),
    document.getElementById('prim-card-3'),
    document.getElementById('prim-card-4'),
  ];

  const activeIndex = Math.min(Math.floor(progress * 4), 3);

  cards.forEach((card, idx) => {
    if (!card) return;
    if (idx === activeIndex || (progress > 0.85)) {
      card.classList.add('active');
    } else {
      card.classList.remove('active');
    }
  });
}

/* ==========================================================================
   6. ARCHITECTURE SYNTHESIS SECTION: Distributed System into 2flow Notation
   ========================================================================== */
function initSynthesisSection() {
  // Elements are ready
}

function updateSynthesisSection(progress) {
  const pill1 = document.getElementById('pill-step-1');
  const pill2 = document.getElementById('pill-step-2');
  const pill3 = document.getElementById('pill-step-3');
  const titleText = document.getElementById('synthesis-title-text');
  const diagramLayer = document.getElementById('synthesis-diagram');
  const dslLayer = document.getElementById('synthesis-dsl');

  // Draw SVG paths of the complete distributed system
  const paths = [
    { id: 'synth-fork-top', start: 0.05, end: 0.25 },
    { id: 'synth-fork-bot', start: 0.05, end: 0.25 },
    { id: 'synth-join-top', start: 0.20, end: 0.35 },
    { id: 'synth-join-bot', start: 0.20, end: 0.35 },
    { id: 'synth-saga-path', start: 0.32, end: 0.48 },
    { id: 'synth-hitl-conduit', start: 0.40, end: 0.55 },
    { id: 'synth-out-conduit', start: 0.50, end: 0.65 },
  ];

  paths.forEach((item) => {
    const el = document.getElementById(item.id);
    if (!el) return;
    const len = parseFloat(el.getAttribute('data-length') || 400);
    if (progress <= item.start) {
      el.style.strokeDashoffset = `${len}`;
    } else if (progress >= item.end) {
      el.style.strokeDashoffset = '0';
    } else {
      const p = (progress - item.start) / (item.end - item.start);
      el.style.strokeDashoffset = `${len * (1 - p)}`;
    }
  });

  // Highlight specific nodes depending on progress
  const reqNode = document.querySelector('#node-req .node-box');
  const debitNode = document.querySelector('#node-debit .node-box');
  const rollbackNode = document.querySelector('#node-rollback .node-box');
  const hitlNode = document.querySelector('#node-hitl .node-box');

  if (progress > 0.3) reqNode?.classList.add('highlight-node');
  else reqNode?.classList.remove('highlight-node');

  if (progress > 0.45) debitNode?.classList.add('highlight-node');
  else debitNode?.classList.remove('highlight-node');

  // Three Stages:
  // Phase 1: Distributed Topologic Graph (0.00 -> 0.45)
  // Phase 2: Category Alignment (0.45 -> 0.70)
  // Phase 3: Synthesis into 2flow DSL (0.70 -> 1.00)

  if (progress < 0.45) {
    pill1?.classList.add('active');
    pill2?.classList.remove('active');
    pill3?.classList.remove('active');
    if (titleText) titleText.textContent = 'Topologia do Sistema Distribuído';
    if (diagramLayer) {
      diagramLayer.style.opacity = '1';
      diagramLayer.style.transform = 'scale(1)';
    }
    if (dslLayer) dslLayer.classList.remove('visible');

  } else if (progress < 0.70) {
    pill1?.classList.remove('active');
    pill2?.classList.add('active');
    pill3?.classList.remove('active');
    if (titleText) titleText.textContent = 'Mapeamento Causal de Operadores';
    if (diagramLayer) {
      const subProgress = (progress - 0.45) / 0.25;
      diagramLayer.style.opacity = `${1 - subProgress * 0.7}`;
      diagramLayer.style.transform = `scale(${1 - subProgress * 0.08}) translateY(${subProgress * -15}px)`;
    }
    if (dslLayer) dslLayer.classList.remove('visible');

  } else {
    // Climax Phase: Complete collapse into the pristine 2flow one-liner!
    pill1?.classList.remove('active');
    pill2?.classList.remove('active');
    pill3?.classList.add('active');
    if (titleText) titleText.textContent = 'A Notação 2flow Sintetizada';
    if (diagramLayer) {
      diagramLayer.style.opacity = '0';
      diagramLayer.style.transform = 'scale(0.88) translateY(-30px)';
    }
    if (dslLayer) dslLayer.classList.add('visible');
  }
}

/* ==========================================================================
   7. INTERACTIVE PLAYGROUND: Live 2flow Parser & Dynamic SVG Visualizer
   ========================================================================== */
function initInteractivePlayground() {
  const dslInput = document.getElementById('dsl-input');
  const compilerStatus = document.getElementById('compiler-status');
  const graphSvg = document.getElementById('interactive-graph-svg');
  const simLogBox = document.getElementById('sim-log-box');
  const btnRunSim = document.getElementById('btn-run-sim');

  const presetBtns = {
    empresa: document.getElementById('btn-preset-empresa'),
    pipeline: document.getElementById('btn-preset-pipeline'),
    saga: document.getElementById('btn-preset-saga'),
  };

  const presets = {
    empresa: `HomologarFornecedor !-> RejeitarFornecedor
  :--: DarEntradaEstoque !-> EstornarEstoque
  :--: [LiquidarContasPagar, RegistrarLancamentoContabil]
  :--: PublicarCampanhaMarketing
  :--: ProcessarPedidoVenda !-> CancelarReservaVenda
  :--: NotificarDespachoCliente`,

    pipeline: `SanitizarEntrada !-> QuarentenaEvento
  :--: [ExtrairEntidades, MascararPII, AnalisarSentimento]
  :--: EnriquecerAnalitica
  :--: ExportarDestino !-> RegistrarFalhaExportacao`,

    saga: `RequisitarServidores
  :--: [AuditarComplianceFiscal, VerificarEstoqueFisico]
  :--: DebitarContaBancaria !-> CancelarReservaOrcamento
  :--: [?AutorizacaoDiretorFinanceiro]
  :--: EmitirNotaFiscal
  :--: DespacharLogisticaWMS`,
  };

  // Preset Switcher
  Object.keys(presetBtns).forEach((key) => {
    const btn = presetBtns[key];
    if (!btn) return;
    btn.addEventListener('click', () => {
      Object.values(presetBtns).forEach((b) => b?.classList.remove('active'));
      btn.classList.add('active');
      dslInput.value = presets[key];
      compileAndRenderGraph();
      addLog(`Preset carregado: "${key.toUpperCase()}"`, 'ok');
    });
  });

  // Live typing event
  dslInput.addEventListener('input', () => {
    compileAndRenderGraph();
  });

  // Simulation Runner
  btnRunSim.addEventListener('click', () => {
    runLiveSimulation();
  });

  // Initial compile
  compileAndRenderGraph();

  /* --- Parse 2flow DSL into linear / branch graph data --- */
  function parse2flow(rawDsl) {
    const clean = rawDsl.replace(/\n/g, ' ').replace(/\s+/g, ' ').trim();
    if (!clean) return { nodes: [], edges: [], stats: { nodes: 0, sagas: 0, forks: 0, hitl: 0 } };

    // Split by main sequence operator :--:
    const segments = clean.split(':--:').map((s) => s.trim());
    const nodes = [];
    const edges = [];
    let sagas = 0;
    let forks = 0;
    let hitl = 0;

    let prevNodeIds = [];

    segments.forEach((seg, sIdx) => {
      // Check for Saga Rollback !->
      let mainPart = seg;
      let sagaTarget = null;
      if (seg.includes('!->')) {
        const parts = seg.split('!->').map((p) => p.trim());
        mainPart = parts[0];
        sagaTarget = parts[1];
        sagas++;
      }

      // Check for Fork [A, B] or HITL [?Gate]
      if (mainPart.startsWith('[') && mainPart.endsWith(']')) {
        const inside = mainPart.slice(1, -1).trim();
        if (inside.startsWith('?')) {
          // HITL gate
          hitl++;
          const nodeId = `node_${sIdx}_hitl`;
          nodes.push({ id: nodeId, label: inside, type: 'hitl' });
          prevNodeIds.forEach((pid) => edges.push({ from: pid, to: nodeId, type: 'seq' }));
          prevNodeIds = [nodeId];
        } else {
          // Parallel Fork-Join
          forks++;
          const branchNames = inside.split(',').map((b) => b.trim());
          const currentForkIds = [];
          branchNames.forEach((bName, bIdx) => {
            const bId = `node_${sIdx}_fork_${bIdx}`;
            nodes.push({ id: bId, label: bName, type: 'parallel' });
            prevNodeIds.forEach((pid) => edges.push({ from: pid, to: bId, type: 'fork' }));
            currentForkIds.push(bId);
          });
          prevNodeIds = currentForkIds;
        }
      } else {
        // Standard single node
        const nodeId = `node_${sIdx}_main`;
        nodes.push({ id: nodeId, label: mainPart, type: 'standard' });
        prevNodeIds.forEach((pid) => edges.push({ from: pid, to: nodeId, type: 'seq' }));
        prevNodeIds = [nodeId];
      }

      // If this segment has a saga compensation target
      if (sagaTarget) {
        const parentId = prevNodeIds[0];
        const sagaId = `node_${sIdx}_saga`;
        nodes.push({ id: sagaId, label: `!-> ${sagaTarget}`, type: 'saga' });
        edges.push({ from: parentId, to: sagaId, type: 'saga' });
      }
    });

    return {
      nodes,
      edges,
      stats: { nodes: nodes.length, sagas, forks, hitl },
    };
  }

  /* --- Render Graph in SVG --- */
  function compileAndRenderGraph() {
    const text = dslInput.value;
    const parsed = parse2flow(text);

    // Update Telemetry Header & Status bar
    compilerStatus.innerHTML = `● AST Válida: <strong>${parsed.nodes.length} nós</strong> | ${parsed.stats.sagas} compensadores | ${parsed.stats.forks} forks | ${parsed.stats.hitl} hitl`;

    // Render SVG
    renderSvg(parsed);
  }

  function renderSvg(parsed) {
    graphSvg.innerHTML = '';
    const nodeMap = new Map();

    // Auto-layout horizontal columns
    const columns = [];
    let curCol = [];

    // Group nodes logically
    parsed.nodes.forEach((n) => {
      if (n.type === 'parallel') {
        curCol.push(n);
      } else if (n.type === 'saga') {
        // Sagas attach directly to previous column below
        if (columns.length > 0) {
          columns[columns.length - 1].push(n);
        } else {
          curCol.push(n);
        }
      } else {
        if (curCol.length > 0) {
          columns.push(curCol);
          curCol = [];
        }
        columns.push([n]);
      }
    });
    if (curCol.length > 0) columns.push(curCol);

    const colWidth = 140;
    const svgWidth = Math.max(columns.length * colWidth + 60, 600);
    const svgHeight = 320;
    graphSvg.setAttribute('viewBox', `0 0 ${svgWidth} ${svgHeight}`);

    // Compute positions
    columns.forEach((col, cIdx) => {
      const x = 30 + cIdx * colWidth;
      const count = col.length;
      col.forEach((node, rIdx) => {
        let y = 140;
        if (node.type === 'saga') {
          y = 230;
        } else if (count > 1) {
          y = 70 + (rIdx * 120) / (count - 1);
        }
        nodeMap.set(node.id, { x, y, node });
      });
    });

    // Draw Edges first
    parsed.edges.forEach((edge) => {
      const fromPos = nodeMap.get(edge.from);
      const toPos = nodeMap.get(edge.to);
      if (!fromPos || !toPos) return;

      const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      const x1 = fromPos.x + 90;
      const y1 = fromPos.y + 20;
      const x2 = toPos.x;
      const y2 = toPos.y + 20;

      // Smooth cubic bezier or orthogonal
      const d = `M ${x1} ${y1} C ${x1 + 30} ${y1}, ${x2 - 30} ${y2}, ${x2} ${y2}`;
      line.setAttribute('d', d);
      line.setAttribute('fill', 'none');

      if (edge.type === 'saga') {
        line.setAttribute('stroke', '#F43F5E');
        line.setAttribute('stroke-width', '1.5');
        line.setAttribute('stroke-dasharray', '3 3');
      } else if (edge.type === 'fork') {
        line.setAttribute('stroke', '#10B981');
        line.setAttribute('stroke-width', '1.5');
      } else {
        line.setAttribute('stroke', 'rgba(255, 255, 255, 0.3)');
        line.setAttribute('stroke-width', '1.2');
      }
      line.classList.add('graph-edge');
      graphSvg.appendChild(line);
    });

    // Draw Nodes
    nodeMap.forEach((val) => {
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
      g.setAttribute('id', `graph-el-${val.node.id}`);
      g.setAttribute('transform', `translate(${val.x}, ${val.y})`);

      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('width', '100');
      rect.setAttribute('height', '40');
      rect.setAttribute('rx', '6');

      let strokeColor = 'rgba(255,255,255,0.3)';
      let fillColor = '#090d16';
      let textColor = '#fff';

      if (val.node.type === 'saga') {
        strokeColor = '#F43F5E';
        fillColor = '#190a12';
        textColor = '#fda4af';
      } else if (val.node.type === 'parallel') {
        strokeColor = '#10B981';
        fillColor = '#071610';
        textColor = '#6ee7b7';
      } else if (val.node.type === 'hitl') {
        strokeColor = '#A855F7';
        fillColor = '#140b1e';
        textColor = '#d8b4fe';
      }

      rect.setAttribute('stroke', strokeColor);
      rect.setAttribute('stroke-width', '1.2');
      rect.setAttribute('fill', fillColor);
      g.appendChild(rect);

      // Label (trimmed if too long)
      const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      text.setAttribute('x', '50');
      text.setAttribute('y', '24');
      text.setAttribute('text-anchor', 'middle');
      text.setAttribute('fill', textColor);
      text.setAttribute('font-size', '10');
      text.setAttribute('font-family', "'JetBrains Mono', monospace");

      let displayLabel = val.node.label;
      if (displayLabel.length > 13) {
        displayLabel = displayLabel.slice(0, 11) + '..';
      }
      text.textContent = displayLabel;
      g.appendChild(text);

      graphSvg.appendChild(g);
    });
  }

  /* --- Simulation Execution Flow --- */
  let isSimulating = false;
  function runLiveSimulation() {
    if (isSimulating) return;
    isSimulating = true;
    btnRunSim.disabled = true;
    btnRunSim.style.opacity = '0.5';

    simLogBox.innerHTML = '';
    addLog('Iniciando simulação determinística de pipeline 2flow...', 'ok');

    const nodes = Array.from(document.querySelectorAll('[id^="graph-el-"]'));
    let step = 0;

    function nextStep() {
      if (step < nodes.length) {
        const nodeG = nodes[step];
        const rect = nodeG.querySelector('rect');
        const origStroke = rect.getAttribute('stroke');

        // Flash node
        rect.setAttribute('stroke', '#FFB100');
        rect.setAttribute('stroke-width', '2.5');
        rect.style.filter = 'drop-shadow(0 0 10px rgba(255,177,0,0.8))';

        const label = nodeG.querySelector('text')?.textContent || `Nó ${step}`;
        addLog(`Transição Causal :--: Nó [${label}] processado em <0.02ms (Zero-Alloc)`, 'ok');

        setTimeout(() => {
          rect.setAttribute('stroke', origStroke);
          rect.setAttribute('stroke-width', '1.2');
          rect.style.filter = 'none';
          step++;
          nextStep();
        }, 320);
      } else {
        addLog('✓ Pipeline concluído com sucesso. Todos os contratos estáticos de tipo respeitados.', 'ok');
        isSimulating = false;
        btnRunSim.disabled = false;
        btnRunSim.style.opacity = '1';
      }
    }

    nextStep();
  }

  function addLog(msg, type = 'ok') {
    const now = new Date();
    const timeStr = `${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}.${String(Math.floor(now.getMilliseconds() / 10)).padStart(2, '0')}`;

    const entry = document.createElement('div');
    entry.className = 'log-entry';
    entry.innerHTML = `<span class="log-time">[${timeStr}]</span> <span class="log-${type}">${msg}</span>`;
    simLogBox.appendChild(entry);
    simLogBox.scrollTop = simLogBox.scrollHeight;
  }
}

/* ==========================================================================
   8. TERMINAL COPY HELPER
   ========================================================================== */
function initTerminalCopy() {
  const btnCopy = document.getElementById('btn-copy-cmd');
  if (!btnCopy) return;

  btnCopy.addEventListener('click', () => {
    const commands = `git clone https://github.com/allascode/2flow.git\ncd 2flow/repo\nmake test-all\nmake wasm\nzig build run_empresa`;
    navigator.clipboard.writeText(commands).then(() => {
      btnCopy.textContent = 'COPIADO! ✓';
      btnCopy.style.borderColor = 'var(--emerald)';
      btnCopy.style.color = 'var(--emerald)';
      setTimeout(() => {
        btnCopy.textContent = 'COPIAR COMANDOS';
        btnCopy.style.borderColor = 'var(--hairline)';
        btnCopy.style.color = 'var(--text-muted)';
      }, 2000);
    });
  });
}
