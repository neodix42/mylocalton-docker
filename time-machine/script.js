class BlockchainGraph {
    constructor() {
        this.svg = d3.select("#graph-svg");
        this.width = 0;
        this.height = 0;
        this.nodes = [];
        this.edges = [];
        this.selectedNode = null;
        this.activeNodeId = null;
        
        this.initializeGraph();
        this.setupEventListeners();
        this.loadGraphData();
        this.startBlockchainStatusUpdates();
    }

    initializeGraph() {
        // Get container dimensions
        const container = document.querySelector('.graph-container');
        this.width = container.clientWidth;
        this.height = container.clientHeight;
        
        // Set SVG dimensions
        this.svg
            .attr("width", this.width)
            .attr("height", this.height);
            
        // Add arrow marker for edges
        this.svg.append("defs").append("marker")
            .attr("id", "arrowhead")
            .attr("viewBox", "0 -5 10 10")
            .attr("refX", 25)
            .attr("refY", 0)
            .attr("markerWidth", 6)
            .attr("markerHeight", 6)
            .attr("orient", "auto")
            .append("path")
            .attr("d", "M0,-5L10,0L0,5")
            .attr("fill", "rgba(14, 132, 184, 0.6)");
            
        // Create groups for edges and nodes
        this.edgeGroup = this.svg.append("g").attr("class", "edges");
        this.nodeGroup = this.svg.append("g").attr("class", "nodes");
        
        // Handle window resize
        window.addEventListener('resize', () => this.handleResize());
    }

    setupEventListeners() {
        // Action buttons
        document.getElementById('take-snapshot-btn').addEventListener('click', () => {
            this.takeSnapshot();
        });
        
        document.getElementById('restore-snapshot-btn').addEventListener('click', () => {
            this.restoreSnapshot();
        });
        
        // Message overlay close
        document.getElementById('message-close').addEventListener('click', () => {
            this.hideMessage();
        });
        
        // Click outside to deselect
        this.svg.on('click', (event) => {
            if (event.target === event.currentTarget) {
                this.selectNode(null);
            }
        });
    }

    async loadGraphData() {
        this.showLoading(true);
        this.updateStatus("Loading graph data...");
        
        try {
            const response = await fetch('/graph', {
                method: 'GET',
                headers: {
                    'Content-Type': 'application/json',
                }
            });
            
            if (response.ok) {
                const data = await response.json();
                if (data.success && data.graph) {
                    this.nodes = data.graph.nodes || [];
                    this.edges = data.graph.edges || [];
                    this.activeNodeId = data.activeNodeId || null;
                } else {
                    // Initialize with root node if no graph exists
                    this.initializeRootNode();
                }
            } else {
                // Initialize with root node if request fails
                this.initializeRootNode();
            }
        } catch (error) {
            console.error('Error loading graph:', error);
            this.initializeRootNode();
        }
        
        this.calculateLayout();
        this.renderGraph();
        this.updateStats();
        this.showLoading(false);
        this.updateStatus("Ready");
    }

    initializeRootNode() {
        this.nodes = [{
            id: "root",
            snapshotNumber: 0,
            blockSequence: 0,
            timestamp: new Date().toISOString(),
            parentId: null,
            isRoot: true,
            type: "root"
        }];
        this.edges = [];
        this.activeNodeId = "root";
    }

    calculateLayout() {
        if (this.nodes.length === 0) return;
        
        // Compact tree layout algorithm
        const tree = this.buildTree();
        const treeLayout = this.calculateTreeLayout(tree);
        
        // Apply calculated positions to nodes
        this.nodes.forEach(node => {
            const layoutNode = treeLayout.find(n => n.id === node.id);
            if (layoutNode) {
                node.x = layoutNode.x;
                node.y = layoutNode.y;
            }
        });
    }

    buildTree() {
        // Build tree structure from nodes and edges
        const nodeMap = new Map();
        this.nodes.forEach(node => {
            nodeMap.set(node.id, {
                ...node,
                children: []
            });
        });
        
        // Add children to parents
        this.edges.forEach(edge => {
            const parent = nodeMap.get(edge.source);
            const child = nodeMap.get(edge.target);
            if (parent && child) {
                parent.children.push(child);
            }
        });
        
        // Find root node
        const root = Array.from(nodeMap.values()).find(n => n.isRoot || !n.parentId);
        return root || nodeMap.values().next().value;
    }

    calculateTreeLayout(root) {
        if (!root) return [];
        
        const levelHeight = 80; // Vertical spacing between levels
        const minHorizontalSpacing = 20; // Minimum horizontal spacing between nodes
        
        // First pass: calculate estimated node widths based on text content
        const estimateNodeWidth = (node) => {
            const displayText = node.isRoot ? "ROOT" : (node.customName || `S${node.snapshotNumber}`);
            const estimatedTextWidth = displayText.length * 8; // Rough estimate: 8px per character
            const padding = 16;
            const minWidth = 60;
            return Math.max(minWidth, estimatedTextWidth + padding);
        };
        
        // Calculate subtree widths considering actual node sizes
        const calculateSubtreeWidth = (node) => {
            const nodeWidth = estimateNodeWidth(node);
            
            if (node.children.length === 0) {
                node.subtreeWidth = nodeWidth;
                return nodeWidth;
            }
            
            let totalChildWidth = 0;
            node.children.forEach(child => {
                totalChildWidth += calculateSubtreeWidth(child);
            });
            
            // Add spacing between children
            if (node.children.length > 1) {
                totalChildWidth += (node.children.length - 1) * minHorizontalSpacing;
            }
            
            // Subtree width is the maximum of node width and total children width
            node.subtreeWidth = Math.max(nodeWidth, totalChildWidth);
            return node.subtreeWidth;
        };
        
        calculateSubtreeWidth(root);
        
        // Second pass: assign positions with proper spacing
        const layout = [];
        const assignPositions = (node, x, y, availableWidth) => {
            // Position current node at center of available width
            node.x = x + availableWidth / 2;
            node.y = y;
            layout.push({
                id: node.id,
                x: node.x,
                y: node.y
            });
            
            // Position children
            if (node.children.length > 0) {
                // Calculate total width needed for all children
                let totalChildrenWidth = 0;
                node.children.forEach(child => {
                    totalChildrenWidth += child.subtreeWidth;
                });
                
                // Add spacing between children
                if (node.children.length > 1) {
                    totalChildrenWidth += (node.children.length - 1) * minHorizontalSpacing;
                }
                
                // Start position for children (centered under parent)
                let currentX = x + (availableWidth - totalChildrenWidth) / 2;
                
                node.children.forEach(child => {
                    const childWidth = child.subtreeWidth;
                    assignPositions(child, currentX, y + levelHeight, childWidth);
                    currentX += childWidth + minHorizontalSpacing;
                });
            }
        };
        
        // Center the tree in the available space
        const totalWidth = root.subtreeWidth;
        const startX = Math.max(50, (this.width - totalWidth) / 2);
        const startY = 50;
        
        assignPositions(root, startX, startY, totalWidth);
        
        return layout;
    }

    calculateNodeLevels() {
        const levels = {};
        const visited = new Set();
        
        // Find root nodes
        const rootNodes = this.nodes.filter(n => n.isRoot || !n.parentId);
        
        // BFS to assign levels
        const queue = rootNodes.map(n => ({ node: n, level: 0 }));
        
        while (queue.length > 0) {
            const { node, level } = queue.shift();
            
            if (visited.has(node.id)) continue;
            visited.add(node.id);
            levels[node.id] = level;
            
            // Add children to queue
            const children = this.nodes.filter(n => n.parentId === node.id);
            children.forEach(child => {
                if (!visited.has(child.id)) {
                    queue.push({ node: child, level: level + 1 });
                }
            });
        }
        
        return levels;
    }

    renderGraph() {
        this.renderEdges();
        this.renderNodes();
    }

    renderEdges() {
        const edgeSelection = this.edgeGroup
            .selectAll(".edge")
            .data(this.edges, d => `${d.source}-${d.target}`);
            
        edgeSelection.exit().remove();
        
        const edgeEnter = edgeSelection.enter()
            .append("line")
            .attr("class", "edge");
            
        edgeSelection.merge(edgeEnter)
            .attr("x1", d => {
                const sourceNode = this.nodes.find(n => n.id === d.source);
                return sourceNode ? sourceNode.x : 0;
            })
            .attr("y1", d => {
                const sourceNode = this.nodes.find(n => n.id === d.source);
                return sourceNode ? sourceNode.y + 20 : 0; // Start from bottom of source node
            })
            .attr("x2", d => {
                const targetNode = this.nodes.find(n => n.id === d.target);
                return targetNode ? targetNode.x : 0;
            })
            .attr("y2", d => {
                const targetNode = this.nodes.find(n => n.id === d.target);
                return targetNode ? targetNode.y - 20 : 0; // End at top of target node
            });
    }

    renderNodes() {
        const nodeSelection = this.nodeGroup
            .selectAll(".node-group")
            .data(this.nodes, d => d.id);
            
        nodeSelection.exit().remove();
        
        const nodeEnter = nodeSelection.enter()
            .append("g")
            .attr("class", "node-group");
            
        // Add rectangle
        nodeEnter.append("rect")
            .attr("class", "node");
            
        // Add label
        nodeEnter.append("text")
            .attr("class", "node-label")
            .attr("dy", "0.35em")
            .attr("text-anchor", "middle");
            
        const nodeUpdate = nodeSelection.merge(nodeEnter);
        
        // Update positions
        nodeUpdate
            .attr("transform", d => `translate(${d.x},${d.y})`);
        
        // Update text content first
        nodeUpdate.select(".node-label")
            .text(d => d.isRoot ? "ROOT" : (d.customName || `S${d.snapshotNumber}`))
            .attr("x", 0)
            .attr("y", 0)
            .on("click", (event, d) => {
                event.stopPropagation();
                if (!d.isRoot) {
                    this.editNodeName(d);
                }
            });

        // Store reference to the class instance
        const self = this;
        
        // Update rectangles with safe text measurement
        nodeUpdate.each(function(d) {
            const group = d3.select(this);
            const text = group.select(".node-label");
            const rect = group.select(".node");
            
            // Safe text dimension calculation
            let textWidth = 40; // Default width
            let textHeight = 16; // Default height
            
            try {
                const textNode = text.node();
                if (textNode) {
                    const textBBox = textNode.getBBox();
                    if (textBBox && textBBox.width > 0) {
                        textWidth = textBBox.width;
                        textHeight = textBBox.height;
                    }
                }
            } catch (error) {
                // Fallback to estimated dimensions based on text length
                const displayText = d.isRoot ? "ROOT" : (d.customName || `S${d.snapshotNumber}`);
                textWidth = displayText.length * 8; // Rough estimate
                textHeight = 16;
            }
            
            const padding = 16;
            const minWidth = 60;
            const minHeight = 30;
            
            // Calculate rectangle dimensions
            const rectWidth = Math.max(minWidth, textWidth + padding);
            const rectHeight = Math.max(minHeight, textHeight + padding);
            
            // Store dimensions on node for layout calculations
            d.width = rectWidth;
            d.height = rectHeight;
            
            // Update rectangle
            rect
                .attr("x", -rectWidth / 2)
                .attr("y", -rectHeight / 2)
                .attr("width", rectWidth)
                .attr("height", rectHeight)
                .attr("rx", 8)
                .attr("ry", 8)
                .attr("class", () => {
                    let classes = "node";
                    if (d.isRoot) classes += " root";
                    else classes += " snapshot";
                    if (d.id === self.activeNodeId) classes += " active";
                    if (d.id === self.selectedNode?.id) classes += " selected";
                    return classes;
                })
                .on("click", (event, nodeData) => {
                    event.stopPropagation();
                    self.selectNode(nodeData);
                })
                .on("dblclick", (event, nodeData) => {
                    event.stopPropagation();
                    if (!nodeData.isRoot) {
                        self.editNodeName(nodeData);
                    }
                });
        });
            
        // Add spinning arrows for active nodes
        this.renderActiveNodeArrows();
    }

    renderActiveNodeArrows() {
        // Remove existing arrows
        this.svg.selectAll('.active-arrows').remove();
        
        const activeNode = this.nodes.find(n => n.id === this.activeNodeId);
        if (!activeNode) return;
        
        // Create spinning arrows group
        const arrowsGroup = this.svg.append('g')
            .attr('class', 'active-arrows')
            .attr('transform', `translate(${activeNode.x}, ${activeNode.y})`);
            
        // Create 4 arrows around the node
        const arrowPositions = [
            { angle: 0, x: 35, y: 0 },
            { angle: 90, x: 0, y: 35 },
            { angle: 180, x: -35, y: 0 },
            { angle: 270, x: 0, y: -35 }
        ];
        
        arrowPositions.forEach((pos, i) => {
            arrowsGroup.append('path')
                .attr('d', 'M-5,-2 L3,0 L-5,2 Z')
                .attr('fill', '#ffc107')
                .attr('stroke', '#e0a800')
                .attr('stroke-width', 1)
                .attr('transform', `translate(${pos.x}, ${pos.y}) rotate(${pos.angle})`)
                .style('animation', `spinArrows 2s linear infinite`)
                .style('animation-delay', `${i * 0.1}s`);
        });
    }

    selectNode(node) {
        this.selectedNode = node;
        
        if (node) {
            this.showActionButtons(node);
            this.showNodeInfo(node);
        } else {
            this.hideActionButtons();
            this.hideNodeInfo();
        }
        
        this.renderNodes(); // Re-render to update selection styling
    }

    showActionButtons(node) {
        const actionButtons = document.getElementById('action-buttons');
        const takeSnapshotBtn = document.getElementById('take-snapshot-btn');
        const restoreSnapshotBtn = document.getElementById('restore-snapshot-btn');
        
        actionButtons.classList.remove('hidden');
        
        // Show/hide appropriate buttons
        takeSnapshotBtn.style.display = 'flex';
        restoreSnapshotBtn.style.display = node.isRoot ? 'none' : 'flex';
    }

    hideActionButtons() {
        document.getElementById('action-buttons').classList.add('hidden');
    }

    editNodeName(node) {
        if (node.isRoot) return;
        
        const currentName = node.customName || `S${node.snapshotNumber}`;
        const newName = prompt(`Enter new name for snapshot:`, currentName);
        
        if (newName !== null && newName.trim() !== '' && newName !== currentName) {
            node.customName = newName.trim();
            this.saveGraph();
            
            // Recalculate layout to prevent overlapping after name change
            this.calculateLayout();
            this.renderGraph();
            
            // Update info panel if this node is selected
            if (this.selectedNode && this.selectedNode.id === node.id) {
                this.showNodeInfo(node);
            }
            
            // Update stats panel
            this.updateStats();
        }
    }

    showNodeInfo(node) {
        const nodeDetails = document.getElementById('node-details');
        const timestamp = new Date(node.timestamp).toLocaleString();
        const displayName = node.isRoot ? 'ROOT' : (node.customName || `S${node.snapshotNumber}`);
        
        // For active node, show current seqno from left panel, otherwise show stored seqno
        let displaySeqno = 'N/A';
        if (node.id === this.activeNodeId) {
            // Get current seqno from left panel
            const currentSeqnoElement = document.getElementById('current-seqno');
            displaySeqno = currentSeqnoElement ? currentSeqnoElement.textContent : (node.seqno !== undefined ? node.seqno : 'N/A');
        } else {
            displaySeqno = node.seqno !== undefined ? node.seqno : 'N/A';
        }
        
        nodeDetails.innerHTML = `
            <p><strong>ID:</strong> ${node.id}</p>
            <p><strong>Name:</strong> ${displayName}</p>
            <p><strong>Seqno:</strong> ${displaySeqno}</p>
            <p><strong>Created:</strong> ${timestamp}</p>
            ${node.parentId ? `<p><strong>Parent:</strong> ${node.parentId}</p>` : ''}
        `;
    }

    hideNodeInfo() {
        document.getElementById('node-details').innerHTML = '<p>Select a node to view details</p>';
    }

    async takeSnapshot() {
        if (!this.selectedNode) return;
        
        this.showLoading(true);
        this.updateStatus("Creating snapshot...");
        
        try {
            // Calculate next sequential snapshot number
            const existingSnapshots = this.nodes.filter(n => !n.isRoot);
            const nextSnapshotNumber = existingSnapshots.length + 1;
            
            // Determine seqno for the new snapshot
            let snapshotSeqno = 0;
            
            if (this.selectedNode.id === this.activeNodeId) {
                // Taking snapshot from active (running) node - get current seqno
                try {
                    const seqnoResponse = await fetch('/seqno-volume', {
                        method: 'GET',
                        headers: {
                            'Content-Type': 'application/json',
                        }
                    });
                    
                    if (seqnoResponse.ok) {
                        const seqnoData = await seqnoResponse.json();
                        if (seqnoData.success && seqnoData.seqno) {
                            snapshotSeqno = seqnoData.seqno;
                        }
                    }
                } catch (seqnoError) {
                    console.error('Error fetching current seqno:', seqnoError);
                    // Continue with seqno = 0 if fetch fails
                }
            } else {
                // Taking snapshot from non-active node - inherit seqno from parent
                snapshotSeqno = this.selectedNode.seqno || 0;
            }
            
            const response = await fetch('/take-snapshot', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    parentId: this.selectedNode.id,
                    snapshotNumber: nextSnapshotNumber
                })
            });
            
            const data = await response.json();
            
            if (data.success) {
                // Create new node with sequential numbering and seqno
                const newNode = {
                    id: `snapshot-${nextSnapshotNumber}`,
                    snapshotNumber: nextSnapshotNumber,
                    blockSequence: data.blockSequence,
                    seqno: snapshotSeqno,
                    timestamp: new Date().toISOString(),
                    parentId: this.selectedNode.id,
                    isRoot: false,
                    type: "snapshot"
                };
                
                // Add node and edge
                this.nodes.push(newNode);
                this.edges.push({
                    source: this.selectedNode.id,
                    target: newNode.id
                });
                
                // Save graph and re-render
                await this.saveGraph();
                this.calculateLayout();
                this.renderGraph();
                this.updateStats();
                
                this.showMessage(`Snapshot ${nextSnapshotNumber} created successfully (seqno: ${snapshotSeqno})`, 'success');
            } else {
                this.showMessage(`Error creating snapshot: ${data.message}`, 'error');
            }
        } catch (error) {
            console.error('Error taking snapshot:', error);
            this.showMessage('Failed to create snapshot. Please try again.', 'error');
        }
        
        this.showLoading(false);
        this.updateStatus("Ready");
    }

    async restoreSnapshot() {
        if (!this.selectedNode || this.selectedNode.isRoot) return;
        
        this.showLoading(true);
        this.updateStatus("Restoring snapshot...");
        
        try {
            // Get current seqno before restoring to store it in the previous active node
            let currentSeqno = 0;
            try {
                const seqnoResponse = await fetch('/seqno-volume', {
                    method: 'GET',
                    headers: {
                        'Content-Type': 'application/json',
                    }
                });
                
                if (seqnoResponse.ok) {
                    const seqnoData = await seqnoResponse.json();
                    if (seqnoData.success && seqnoData.seqno) {
                        currentSeqno = seqnoData.seqno;
                    }
                }
            } catch (seqnoError) {
                console.error('Error fetching current seqno before restore:', seqnoError);
            }
            
            // Store current seqno in the previous active node
            if (this.activeNodeId) {
                const previousActiveNode = this.nodes.find(n => n.id === this.activeNodeId);
                if (previousActiveNode) {
                    previousActiveNode.seqno = currentSeqno;
                }
            }
            
            const response = await fetch('/restore-snapshot', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    snapshotId: this.selectedNode.id,
                    snapshotNumber: this.selectedNode.snapshotNumber
                })
            });
            
            const data = await response.json();
            
            if (data.success) {
                // Update active node
                this.activeNodeId = this.selectedNode.id;
                
                // Save graph and re-render
                await this.saveGraph();
                this.renderGraph();
                this.updateStats();
                
                // Show success message briefly, then show "Starting blockchain..."
                this.showMessage(`Snapshot restored successfully: ${this.selectedNode.id}`, 'success');
                
                // After a short delay, show "Starting blockchain..." and wait for valid seqno
                setTimeout(() => {
                    this.isWaitingForBlockchain = true;
                    this.updateStatus("Starting blockchain...");
                    this.waitForValidSeqno();
                }, 2000); // Wait 2 seconds to let user see the success message
            } else {
                this.showMessage(`Error restoring snapshot: ${data.message}`, 'error');
                this.showLoading(false);
                this.updateStatus("Not Ready");
            }
        } catch (error) {
            console.error('Error restoring snapshot:', error);
            this.showMessage('Failed to restore snapshot. Please try again.', 'error');
            this.showLoading(false);
            this.updateStatus("Not Ready");
        }
    }

    async saveGraph() {
        try {
            const graphData = {
                nodes: this.nodes,
                edges: this.edges,
                activeNodeId: this.activeNodeId,
                lastUpdated: new Date().toISOString()
            };
            
            const response = await fetch('/graph', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ graph: graphData })
            });
            
            if (!response.ok) {
                console.error('Failed to save graph data');
            }
        } catch (error) {
            console.error('Error saving graph:', error);
        }
    }

    updateStats() {
        const totalSnapshots = this.nodes.filter(n => !n.isRoot).length;
        const activeNode = this.nodes.find(n => n.id === this.activeNodeId);
        
        document.getElementById('total-snapshots').textContent = totalSnapshots;
        document.getElementById('active-node').textContent = 
            activeNode ? (activeNode.isRoot ? 'Root' : (activeNode.customName || `S${activeNode.snapshotNumber}`)) : 'None';
    }

    showLoading(show) {
        const spinner = document.getElementById('loading-spinner');
        if (show) {
            spinner.classList.remove('hidden');
        } else {
            spinner.classList.add('hidden');
        }
    }

    updateStatus(message) {
        document.getElementById('status-text').textContent = message;
    }

    showMessage(message, type = 'info') {
        // Show message in the status area instead of modal dialog
        this.updateStatus(message);
        
        // Change status text color based on message type
        const statusText = document.getElementById('status-text');
        if (type === 'success') {
            statusText.style.color = '#28a745';
        } else if (type === 'error') {
            statusText.style.color = '#dc3545';
        } else {
            statusText.style.color = '#555';
        }
        
        // Only auto-reset for error messages, not for success messages during blockchain operations
        if (type === 'error') {
            setTimeout(() => {
                this.updateStatus("Ready");
                statusText.style.color = '#555';
            }, 3000);
        }
    }

    hideMessage() {
        // No longer needed since we're not using modal dialogs
        // Keep method for compatibility
    }

    startBlockchainStatusUpdates() {
        // Update immediately
        this.updateBlockchainStatus();

        // Then update every 2 seconds
        setInterval(() => {
            this.updateBlockchainStatus();
        }, 2000);
    }

    async updateBlockchainStatus() {
        try {
            const response = await fetch('/seqno-volume', {
                method: 'GET',
                headers: {
                    'Content-Type': 'application/json',
                }
            });
            
            if (response.ok) {
                const data = await response.json();
                if (data.success) {
                    document.getElementById('current-seqno').textContent = data.seqno || 'N/A';
                    
                    // Convert volume name to snapshot name
                    const snapshotName = this.getSnapshotNameFromVolume(data.volume);
                    document.getElementById('current-snapshot-name').textContent = snapshotName;
                    
                    // Update active node if it changed
                    this.updateActiveNodeFromVolume(data.volume);
                    
                    // If active node is selected, update the right panel with current seqno
                    if (this.selectedNode && this.selectedNode.id === this.activeNodeId) {
                        this.showNodeInfo(this.selectedNode);
                    }
                } else {
                    document.getElementById('current-seqno').textContent = 'Error';
                    document.getElementById('current-snapshot-name').textContent = 'Error';
                }
            } else {
                document.getElementById('current-seqno').textContent = 'Error';
                document.getElementById('current-snapshot-name').textContent = 'Error';
            }
        } catch (error) {
            console.error('Error fetching blockchain status:', error);
            document.getElementById('current-seqno').textContent = 'Error';
            document.getElementById('current-snapshot-name').textContent = 'Error';
        }
        
    }

    getSnapshotNameFromVolume(volumeName) {
        if (!volumeName) return 'N/A';
        
        if (volumeName.startsWith('ton-db-snapshot-')) {
            // Extract snapshot number from volume name
            const numberPart = volumeName.substring('ton-db-snapshot-'.length);
            const snapshotNumber = parseInt(numberPart);
            
            // Find the node with this snapshot number
            const node = this.nodes.find(n => n.snapshotNumber === snapshotNumber);
            if (node && node.customName) {
                return node.customName;
            } else {
                return `S${snapshotNumber}`;
            }
        } else {
            return 'Root'; // Using root/original volume
        }
    }

    updateActiveNodeFromVolume(volumeName) {
        if (!volumeName) return;
        
        let newActiveNodeId = null;
        
        if (volumeName.startsWith('ton-db-snapshot-')) {
            // Extract snapshot number from volume name
            const numberPart = volumeName.substring('ton-db-snapshot-'.length);
            const snapshotNumber = parseInt(numberPart);
            
            // Find the node with this snapshot number
            const node = this.nodes.find(n => n.snapshotNumber === snapshotNumber);
            if (node) {
                newActiveNodeId = node.id;
            }
        } else {
            // Using root volume
            newActiveNodeId = 'root';
        }
        
        // Update active node if it changed
        if (newActiveNodeId && newActiveNodeId !== this.activeNodeId) {
            this.activeNodeId = newActiveNodeId;
            this.renderGraph();
            this.updateStats();
        }
    }

    waitForValidSeqno() {
        const checkSeqno = async () => {
            try {
                const response = await fetch('/seqno-volume', {
                    method: 'GET',
                    headers: {
                        'Content-Type': 'application/json',
                    }
                });
                
                if (response.ok) {
                    const data = await response.json();
                    if (data.success && data.seqno && data.seqno > 0) {
                        // Valid seqno received, blockchain is ready
                        this.isWaitingForBlockchain = false;
                        this.showLoading(false);
                        this.updateStatus("Ready");
                        return true;
                    }
                }
            } catch (error) {
                console.error('Error checking seqno during startup:', error);
            }
            return false;
        };
        
        // Check every 2 seconds for valid seqno
        const intervalId = setInterval(async () => {
            const isReady = await checkSeqno();
            if (isReady) {
                clearInterval(intervalId);
            }
        }, 2000);
        
        // Also check immediately
        checkSeqno().then(isReady => {
            if (isReady) {
                clearInterval(intervalId);
            }
        });
    }

    handleResize() {
        const container = document.querySelector('.graph-container');
        this.width = container.clientWidth;
        this.height = container.clientHeight;
        
        this.svg
            .attr("width", this.width)
            .attr("height", this.height);
            
        this.calculateLayout();
        this.renderGraph();
    }
}

// Initialize the graph when the page loads
window.addEventListener('load', () => {
    new BlockchainGraph();
});
