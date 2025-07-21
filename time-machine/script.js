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
        
        const nodeSize = 50; // Node diameter + spacing
        const levelHeight = 80; // Vertical spacing between levels
        const minHorizontalSpacing = 60; // Minimum horizontal spacing
        
        // First pass: calculate subtree widths
        const calculateSubtreeWidth = (node) => {
            if (node.children.length === 0) {
                node.subtreeWidth = nodeSize;
                return nodeSize;
            }
            
            let totalChildWidth = 0;
            node.children.forEach(child => {
                totalChildWidth += calculateSubtreeWidth(child);
            });
            
            node.subtreeWidth = Math.max(nodeSize, totalChildWidth);
            return node.subtreeWidth;
        };
        
        calculateSubtreeWidth(root);
        
        // Second pass: assign positions
        const layout = [];
        const assignPositions = (node, x, y, availableWidth) => {
            // Position current node
            node.x = x + availableWidth / 2;
            node.y = y;
            layout.push({
                id: node.id,
                x: node.x,
                y: node.y
            });
            
            // Position children
            if (node.children.length > 0) {
                let currentX = x;
                node.children.forEach(child => {
                    const childWidth = child.subtreeWidth;
                    assignPositions(child, currentX, y + levelHeight, childWidth);
                    currentX += childWidth;
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
            
        // Add circle
        nodeEnter.append("circle")
            .attr("class", "node")
            .attr("r", 20);
            
        // Add label
        nodeEnter.append("text")
            .attr("class", "node-label")
            .attr("dy", "0.35em");
            
        const nodeUpdate = nodeSelection.merge(nodeEnter);
        
        // Update positions
        nodeUpdate
            .attr("transform", d => `translate(${d.x},${d.y})`);
            
        // Update circles
        nodeUpdate.select(".node")
            .attr("class", d => {
                let classes = "node";
                if (d.isRoot) classes += " root";
                else classes += " snapshot";
                if (d.id === this.activeNodeId) classes += " active";
                if (d.id === this.selectedNode?.id) classes += " selected";
                return classes;
            })
            .on("click", (event, d) => {
                event.stopPropagation();
                this.selectNode(d);
            });
            
        // Update labels
        nodeUpdate.select(".node-label")
            .text(d => d.isRoot ? "ROOT" : `S${d.snapshotNumber}`);
            
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
        
        // Position buttons to the right of the selected node
        actionButtons.style.left = `${node.x + 80}px`;
        actionButtons.style.top = `${node.y - 30}px`;
        actionButtons.style.transform = 'none';
        
        // Show/hide appropriate buttons
        takeSnapshotBtn.style.display = 'flex';
        restoreSnapshotBtn.style.display = node.isRoot ? 'none' : 'flex';
    }

    hideActionButtons() {
        document.getElementById('action-buttons').classList.add('hidden');
    }

    showNodeInfo(node) {
        const nodeDetails = document.getElementById('node-details');
        const timestamp = new Date(node.timestamp).toLocaleString();
        
        nodeDetails.innerHTML = `
            <p><strong>ID:</strong> ${node.id}</p>
            <p><strong>Snapshot #:</strong> ${node.snapshotNumber}</p>
            <p><strong>Block Sequence:</strong> ${node.blockSequence}</p>
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
                // Create new node with sequential numbering
                const newNode = {
                    id: `snapshot-${nextSnapshotNumber}`,
                    snapshotNumber: nextSnapshotNumber,
                    blockSequence: data.blockSequence,
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
                
                this.showMessage(`Snapshot ${nextSnapshotNumber} created successfully`, 'success');
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
                
                this.showMessage(`Snapshot restored successfully: ${this.selectedNode.id}`, 'success');
            } else {
                this.showMessage(`Error restoring snapshot: ${data.message}`, 'error');
            }
        } catch (error) {
            console.error('Error restoring snapshot:', error);
            this.showMessage('Failed to restore snapshot. Please try again.', 'error');
        }
        
        this.showLoading(false);
        this.updateStatus("Ready");
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
            activeNode ? (activeNode.isRoot ? 'Root' : `Snapshot ${activeNode.snapshotNumber}`) : 'None';
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
        
        // Auto-reset to "Ready" after 3 seconds
        setTimeout(() => {
            this.updateStatus("Ready");
            statusText.style.color = '#555';
        }, 3000);
    }

    hideMessage() {
        // No longer needed since we're not using modal dialogs
        // Keep method for compatibility
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
