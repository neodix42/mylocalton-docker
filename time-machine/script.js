class BlockchainGraph {
    constructor() {
        this.svg = d3.select("#graph-svg");
        this.width = 0;
        this.height = 0;
        this.nodes = [];
        this.edges = [];
        this.selectedNode = null;
        this.activeNodeId = null;
        this.isOperationInProgress = false; // Flag to prevent re-highlighting during operations
        this.shouldShowActiveHighlight = true; // Flag to control visual highlighting
        
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
        // Admin links
        document.getElementById('take-snapshot-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.takeSnapshot();
        });
        
        document.getElementById('restore-snapshot-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.restoreSnapshot();
        });
        
        document.getElementById('delete-snapshot-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.deleteSnapshot();
        });
        
        document.getElementById('stop-blockchain-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.stopBlockchain();
        });
        
        document.getElementById('start-blockchain-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.startBlockchain();
        });
        
        // Message overlay close
        document.getElementById('message-close').addEventListener('click', () => {
            this.hideMessage();
        });
        
        // Clean up functionality
        document.getElementById('clean-up-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.cleanUp();
        });
        
        // Reset functionality
        document.getElementById('start-over-link').addEventListener('click', (e) => {
            e.preventDefault();
            this.showResetConfirmation();
        });
        
        // Reset confirmation modal
        document.getElementById('reset-confirm-no').addEventListener('click', () => {
            this.hideResetConfirmation();
        });
        
        document.getElementById('reset-confirm-yes').addEventListener('click', () => {
            this.hideResetConfirmation();
            this.showResetConfiguration();
        });
        
        // Delete confirmation modal
        document.getElementById('delete-confirm-no').addEventListener('click', () => {
            this.hideDeleteConfirmation();
        });
        
        document.getElementById('delete-confirm-yes').addEventListener('click', () => {
            this.hideDeleteConfirmation();
            this.proceedWithDelete();
        });
        
        // Stop blockchain confirmation modal
        document.getElementById('stop-confirm-no').addEventListener('click', () => {
            this.hideStopConfirmation();
        });
        
        document.getElementById('stop-confirm-yes').addEventListener('click', () => {
            this.hideStopConfirmation();
            this.proceedWithStop();
        });
        
        // Clean up confirmation modal
        document.getElementById('cleanup-confirm-no').addEventListener('click', () => {
            this.hideCleanupConfirmation();
        });
        
        document.getElementById('cleanup-confirm-yes').addEventListener('click', () => {
            this.hideCleanupConfirmation();
            this.proceedWithCleanup();
        });
        
        // Reset configuration modal
        document.getElementById('reset-config-cancel').addEventListener('click', () => {
            this.hideResetConfiguration();
        });
        
        document.getElementById('reset-config-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this.submitResetConfiguration();
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

        // Ensure active node is properly marked after page refresh
        if (this.activeNodeId) {
            this.renderActiveNodeArrows();
        }
        
        this.showLoading(false);
        this.updateStatus("Ready");
    }

    initializeRootNode() {
        this.nodes = [{
            id: "0",
            snapshotNumber: 0,
            seqno: 0,
            timestamp: new Date().toISOString(),
            parentId: null,
            isRoot: true,
            type: "root"
        }];
        this.edges = [];
        this.activeNodeId = "0";
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
            const displayText = node.isRoot ? "Genesis" : (node.customName || `S${node.snapshotNumber}`);
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
            .text(d => {
                if (d.isRoot) return "Genesis";
                if (d.type === "instance") {
                    // If instance has custom name, use it as-is. Otherwise, use default format with instance number
                    return d.customName || `S${d.snapshotNumber}-${d.instanceNumber || "1"}`;
                }
                return d.customName || `S${d.snapshotNumber}`;
            })
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
                const displayText = d.isRoot ? "Genesis" : (d.customName || `S${d.snapshotNumber}`);
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
                    else if (d.type === "instance") classes += " instance";
                    else classes += " snapshot";
                    if (d.id === self.activeNodeId && self.shouldShowActiveHighlight) classes += " active";
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
        if (!activeNode || !this.shouldShowActiveHighlight) return;
        
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
            this.showAdminLinks(node);
            this.showNodeInfo(node);
        } else {
            this.hideAdminLinks();
            this.hideNodeInfo();
        }
        
        this.renderNodes(); // Re-render to update selection styling
    }

    showAdminLinks(node) {
        const adminLinks = document.getElementById('admin-links');
        const adminPlaceholder = document.getElementById('admin-placeholder');
        const takeSnapshotLink = document.getElementById('take-snapshot-link');
        const restoreSnapshotLink = document.getElementById('restore-snapshot-link');
        const deleteSnapshotLink = document.getElementById('delete-snapshot-link');
        const startBlockchainLink = document.getElementById('start-blockchain-link');
        const stopBlockchainLink = document.getElementById('stop-blockchain-link');
        
        // Show admin links and hide placeholder
        adminLinks.classList.remove('hidden');
        adminPlaceholder.classList.add('hidden');
        
        // Show/hide appropriate links based on node type
        takeSnapshotLink.style.display = 'block';
        restoreSnapshotLink.style.display = node.isRoot ? 'none' : 'block';
        deleteSnapshotLink.style.display = node.isRoot ? 'none' : 'block';
        startBlockchainLink.style.display = node.isRoot ? 'block' : 'none';
        
    }

    hideAdminLinks() {
        const adminLinks = document.getElementById('admin-links');
        const adminPlaceholder = document.getElementById('admin-placeholder');
        
        // Hide admin links and show placeholder
        adminLinks.classList.add('hidden');
        adminPlaceholder.classList.remove('hidden');
    }

    editNodeName(node) {
        if (node.isRoot) return;
        
        // For instance nodes, use their own default name format, not parent's
        let currentName;
        if (node.type === "instance") {
            currentName = node.customName || `S${node.snapshotNumber}-${node.instanceNumber || "1"}`;
        } else {
            currentName = node.customName || `S${node.snapshotNumber}`;
        }
        
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
        }
    }
    showNodeInfo(node) {
        const nodeDetails = document.getElementById('node-details');
        const timestamp = new Date(node.timestamp).toLocaleString();
        let displayName;
        if (node.isRoot) {
            displayName = 'Genesis';
        } else if (node.type === "instance") {
            // If instance has custom name, use it as-is. Otherwise, use default format with instance number
            displayName = node.customName || `S${node.snapshotNumber}-${node.instanceNumber || "1"}`;
        } else {
            displayName = node.customName || `S${node.snapshotNumber}`;
        }
        
        // For active node, show current seqno from left panel, otherwise show stored seqno
        let displaySeqno = 'N/A';
        if (node.id === this.activeNodeId) {
            // Get current seqno from left panel
            const currentSeqnoElement = document.getElementById('current-seqno');
            displaySeqno = currentSeqnoElement ? currentSeqnoElement.textContent : (node.seqno !== undefined ? node.seqno : 'N/A');
        } else {
            displaySeqno = node.seqno !== undefined ? node.seqno : 'N/A';
        }
        
        // Get active nodes count - will be fetched and updated
        let activeNodesHtml = '<p><strong>Nodes:</strong> <span id="active-nodes-count">Loading...</span></p>';
        
        nodeDetails.innerHTML = `
            <p><strong>ID:</strong> ${node.id}</p>
            <p><strong>Name:</strong> ${displayName}</p>
            <p><strong>Type:</strong> ${node.type || 'snapshot'}</p>
            <p><strong>Seqno:</strong> ${displaySeqno}</p>
            <p><strong>Created:</strong> ${timestamp}</p>
            ${activeNodesHtml}
        `;
        
        // Fetch and update active nodes count
        this.updateActiveNodesCount(node);
    }

    hideNodeInfo() {
        document.getElementById('node-details').innerHTML = '<p>Select a node to view details</p>';
    }

    async updateActiveNodesCount(node) {
        const activeNodesElement = document.getElementById('active-nodes-count');
        if (!activeNodesElement) return;
        
        // Always use stored value or inherit from parent - no real-time fetching
        let activeNodesCount = 'N/A';
        
        if (node && node.activeNodes !== undefined) {
            // Use stored value if available
            activeNodesCount = node.activeNodes;
        } else if (node && node.parentId) {
            // Inherit from parent node if no stored value
            const parentNode = this.nodes.find(n => n.id === node.parentId);
            if (parentNode && parentNode.activeNodes !== undefined) {
                activeNodesCount = parentNode.activeNodes;
                // Store inherited value in current node
                node.activeNodes = parentNode.activeNodes;
            }
        }
        
        activeNodesElement.textContent = activeNodesCount;
    }

    async takeSnapshot() {
        if (!this.selectedNode) return;
        
        // Store the selected node at the start to prevent issues if selection changes during operation
        const snapshotParentNode = this.selectedNode;
        
        // Clear any previous error state when starting a new action
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Preparing snapshot...");
        
        try {
            // Calculate next sequential snapshot number
            const existingSnapshots = this.nodes.filter(n => !n.isRoot);
            const nextSnapshotNumber = existingSnapshots.length + 1;
            
            
            // Start polling for status updates
            const statusPolling = this.startSnapshotStatusPolling();
            
            const response = await fetch('/take-snapshot', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    parentId: this.selectedNode.isRoot ? 0: snapshotParentNode.id,
                    snapshotNumber: nextSnapshotNumber
                })
            });
            
            const data = await response.json();
            
            // Stop status polling after getting response
            clearInterval(statusPolling);
            
            // Reset operation flags and restore highlighting
            this.isOperationInProgress = false;
            this.shouldShowActiveHighlight = true;
            
            if (data.success) {
                // Get active nodes count to store in the new snapshot
                let activeNodesCount = 0;
                
                // First, try to get from backend response
                if (data.activeNodes !== undefined) {
                    activeNodesCount = data.activeNodes;
                } else {
                    // If backend didn't provide it, inherit from parent node
                    if (snapshotParentNode.activeNodes !== undefined) {
                        activeNodesCount = snapshotParentNode.activeNodes;
                    } else if (snapshotParentNode.id === this.activeNodeId) {
                        // If parent is currently active, try to get current active nodes count
                        try {
                            const activeNodesResponse = await fetch('/active-nodes', {
                                method: 'GET',
                                headers: {
                                    'Content-Type': 'application/json',
                                }
                            });
                            
                            if (activeNodesResponse.ok) {
                                const activeNodesData = await activeNodesResponse.json();
                                if (activeNodesData.success) {
                                    activeNodesCount = activeNodesData.activeNodes || 0;
                                }
                            }
                        } catch (error) {
                            console.warn('Could not fetch active nodes count for snapshot:', error);
                        }
                    } else if (snapshotParentNode.isRoot) {
                        // If parent is ROOT, inherit from ROOT's active nodes or get current count
                        if (snapshotParentNode.activeNodes !== undefined) {
                            activeNodesCount = snapshotParentNode.activeNodes;
                        } else {
                            // ROOT doesn't have stored active nodes, get current count
                            try {
                                const activeNodesResponse = await fetch('/active-nodes', {
                                    method: 'GET',
                                    headers: {
                                        'Content-Type': 'application/json',
                                    }
                                });
                                
                                if (activeNodesResponse.ok) {
                                    const activeNodesData = await activeNodesResponse.json();
                                    if (activeNodesData.success) {
                                        activeNodesCount = activeNodesData.activeNodes || 0;
                                        // Store it in ROOT for future reference
                                        snapshotParentNode.activeNodes = activeNodesCount;
                                    }
                                }
                            } catch (error) {
                                console.warn('Could not fetch active nodes count for ROOT:', error);
                            }
                        }
                    }
                }
                
                // Create new node with sequential numbering
                const newNode = {
                    id: `${nextSnapshotNumber}`,
                    snapshotNumber: nextSnapshotNumber,
                    seqno: snapshotParentNode.id === this.activeNodeId ? data.seqno : (snapshotParentNode.seqno || data.seqno),
                    timestamp: new Date().toISOString(),
                    parentId: snapshotParentNode.id,
                    isRoot: false,
                    type: "snapshot",
                    activeNodes: activeNodesCount
                };
                
                // Add node and edge
                this.nodes.push(newNode);
                this.edges.push({
                    source: snapshotParentNode.id,
                    target: newNode.id
                });
                
                // Save graph and re-render
                await this.saveGraph();
                this.calculateLayout();
                this.renderGraph();

                // Show appropriate success message based on whether blockchain was shutdown
                let successMessage = `Snapshot ${nextSnapshotNumber} created successfully`;
                if (data.blockchainShutdown) {
                    successMessage += ' - Blockchain was shutdown and restarted for consistent snapshot';
                }
                this.showMessage(successMessage, 'success');
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

    startSnapshotStatusPolling() {
        return setInterval(async () => {
            try {
                const response = await fetch('/snapshot-status', {
                    method: 'GET',
                    headers: {
                        'Content-Type': 'application/json',
                    }
                });
                
                if (response.ok) {
                    const data = await response.json();
                    if (data.status) {
                        this.updateStatus(data.status);
                        
                        // Set operation flag and control visual highlighting when not ready
                        if (data.status !== "Ready") {
                            this.isOperationInProgress = true;
                            this.shouldShowActiveHighlight = false;
                            this.renderGraph(); // Re-render to remove visual highlighting
                        } else {
                            this.isOperationInProgress = false;
                            this.shouldShowActiveHighlight = true;
                            this.renderGraph(); // Re-render to restore visual highlighting
                        }
                    }
                }
            } catch (error) {
                console.warn('Error polling snapshot status:', error);
            }
        }, 500); // Poll every 500ms for responsive updates
    }

    async restoreSnapshot() {
        if (!this.selectedNode || this.selectedNode.isRoot) return;
        
        // Store the selected node at the start to prevent issues if selection changes during operation
        const restoreTargetNode = this.selectedNode;
        
        // Clear any previous error state when starting a new action
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Restoring snapshot...");
        
        try {

            // Start polling for status updates
            const statusPolling = this.startSnapshotStatusPolling();
            
            const response = await fetch('/restore-snapshot', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    snapshotId: restoreTargetNode.id,
                    snapshotNumber: restoreTargetNode.snapshotNumber,
                    nodeType: restoreTargetNode.type || "snapshot",
                    instanceNumber: restoreTargetNode.instanceNumber,
                    seqno: restoreTargetNode.seqno
                })
            });

            const data = await response.json();
            
            // Stop status polling after getting response
            clearInterval(statusPolling);
            
            // Reset operation flags and restore highlighting
            this.isOperationInProgress = false;
            this.shouldShowActiveHighlight = true;
            
            if (data.success) {
                // Save the last known seqno to the previous active node if provided by backend
                if (data.lastKnownSeqno && data.lastKnownSeqno > 0 && this.activeNodeId) {
                    const previousActiveNode = this.nodes.find(n => n.id === this.activeNodeId);
                    if (previousActiveNode) {
                        previousActiveNode.seqno = data.lastKnownSeqno;
                        previousActiveNode.lastSeqnoUpdate = new Date().toISOString();
                        console.log(`Saved last known seqno ${data.lastKnownSeqno} to previous active node ${this.activeNodeId} before restoration`);
                        
                        // Save the graph immediately to persist this seqno update
                        await this.saveGraph();
                    }
                }
                
                if (data.isNewInstance) {
                    // Restoring from snapshot node - create new instance node
                    const instanceNumber = data.instanceNumber || 1;
                    
                    // Create new instance node with clean ID (no timestamp)
                    // const instanceNodeId = restoreTargetNode.id + "-" + instanceNumber;
                    
                    // Create new instance node
                    const instanceNode = {
                        id: data.id,
                        snapshotNumber: restoreTargetNode.snapshotNumber,
                        instanceNumber: instanceNumber,
                        seqno: restoreTargetNode.seqno,
                        timestamp: new Date().toISOString(),
                        parentId: restoreTargetNode.id,
                        isRoot: false,
                        type: "instance",
                        // Don't inherit customName from parent - let instance have its own name
                        activeNodes: restoreTargetNode.activeNodes // Inherit active nodes count from parent
                    };
                    
                    // Add instance node and edge
                    this.nodes.push(instanceNode);
                    this.edges.push({
                        source: restoreTargetNode.id,
                        target: data.id
                    });
                    
                    // Update active node to the new instance
                    this.activeNodeId = data.id;
                } else {
                    // Restoring from instance node - reuse existing node, just update active
                    this.activeNodeId = restoreTargetNode.id;
                }
                
                // Save graph and re-render
                await this.saveGraph();
                this.calculateLayout();
                this.renderGraph();

                this.showMessage("Snapshot restored successfully", 'success');
                
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

    async deleteSnapshot() {
        if (!this.selectedNode || this.selectedNode.isRoot) return;
        
        // Check if the selected node is currently active
        if (this.selectedNode.id === this.activeNodeId) {
            this.showMessage('Cannot delete the currently active snapshot. Please switch to a different snapshot first.', 'error');
            return;
        }
        
        // Get all descendants (children, grandchildren, etc.) that would be deleted
        const allDescendants = this.collectNodeAndDescendants(this.selectedNode.id);
        
        // Check if any descendant (including the selected node itself) is currently active
        const activeDescendant = allDescendants.find(node => node.id === this.activeNodeId);
        if (activeDescendant) {
            const activeNodeName = activeDescendant.customName || `S${activeDescendant.snapshotNumber}${activeDescendant.type === "instance" ? `-${activeDescendant.instanceNumber}` : ""}`;
            if (activeDescendant.id === this.selectedNode.id) {
                this.showMessage('Cannot delete the currently active snapshot. Please switch to a different snapshot first.', 'error');
            } else {
                this.showMessage(`Cannot delete snapshot because its descendant "${activeNodeName}" is currently active. Please switch to a different snapshot first.`, 'error');
            }
            return;
        }
        
        // Check if this node has children (siblings)
        const children = this.nodes.filter(n => n.parentId === this.selectedNode.id);
        const hasChildren = children.length > 0;
        
        let confirmMessage = `Are you sure you want to delete snapshot "${this.selectedNode.customName || `S${this.selectedNode.snapshotNumber}`}"?`;
        
        if (hasChildren) {
            const childNames = children.map(child => 
                child.customName || `S${child.snapshotNumber}${child.type === "instance" ? `-${child.instanceNumber}` : ""}`
            ).join(", ");
            confirmMessage += `\n\nWARNING: This snapshot has ${children.length} child snapshot(s): ${childNames}.\nDeleting this snapshot will also delete all its children. This action cannot be undone.`;
        }
        
        // Store the confirmation message and show modal
        this.pendingDeleteMessage = confirmMessage;
        this.showDeleteConfirmation();
        return;
    }

    showDeleteConfirmation() {
        const modal = document.getElementById('delete-confirmation-modal');
        const messageElement = document.getElementById('delete-confirmation-message');
        messageElement.textContent = this.pendingDeleteMessage;
        modal.classList.remove('hidden');
    }

    hideDeleteConfirmation() {
        const modal = document.getElementById('delete-confirmation-modal');
        modal.classList.add('hidden');
    }

    async proceedWithDelete() {
        // Clear any previous error state when starting a new action
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Deleting snapshot...");
        
        try {
            // Check if this node has children (siblings)
            const children = this.nodes.filter(n => n.parentId === this.selectedNode.id);
            const hasChildren = children.length > 0;
            
            // Collect all nodes that will be deleted (selected node + all descendants)
            const nodesToDelete = this.collectNodeAndDescendants(this.selectedNode.id);
            
            const response = await fetch('/delete-snapshot', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    snapshotId: this.selectedNode.id,
                    snapshotNumber: this.selectedNode.snapshotNumber,
                    nodeType: this.selectedNode.type || "snapshot",
                    instanceNumber: this.selectedNode.instanceNumber,
                    hasChildren: hasChildren,
                    nodesToDelete: nodesToDelete
                })
            });
            
            const data = await response.json();
            
            if (data.success) {
                // Remove the node and all its descendants from the graph
                this.removeNodeAndDescendants(this.selectedNode.id);
                
                // If the deleted node was active, set active to root
                if (this.activeNodeId === this.selectedNode.id || 
                    (hasChildren && children.some(child => child.id === this.activeNodeId))) {
                    this.activeNodeId = "0";
                }
                
                // Clear selection
                this.selectedNode = null;
                this.hideAdminLinks();
                this.hideNodeInfo();
                
                // Save graph and re-render
                await this.saveGraph();
                this.calculateLayout();
                this.renderGraph();

                this.showMessage(`Snapshot deleted successfully`, 'success');
            } else {
                this.showMessage(`Error deleting snapshot: ${data.message}`, 'error');
            }
        } catch (error) {
            console.error('Error deleting snapshot:', error);
            this.showMessage('Failed to delete snapshot. Please try again.', 'error');
        }
        
        this.showLoading(false);
        this.updateStatus("Ready");
    }

    collectNodeAndDescendants(nodeId) {
        // Find all descendants recursively and return their details
        const toRemove = new Set([nodeId]);
        let changed = true;
        
        while (changed) {
            changed = false;
            this.nodes.forEach(node => {
                if (!toRemove.has(node.id) && node.parentId && toRemove.has(node.parentId)) {
                    toRemove.add(node.id);
                    changed = true;
                }
            });
        }
        
        // Return node details for all nodes to be deleted
        return this.nodes
            .filter(node => toRemove.has(node.id))
            .map(node => ({
                id: node.id,
                snapshotNumber: node.snapshotNumber,
                instanceNumber: node.instanceNumber,
                type: node.type || "snapshot"
            }));
    }

    removeNodeAndDescendants(nodeId) {
        // Find all descendants recursively
        const toRemove = new Set([nodeId]);
        let changed = true;
        
        while (changed) {
            changed = false;
            this.nodes.forEach(node => {
                if (!toRemove.has(node.id) && node.parentId && toRemove.has(node.parentId)) {
                    toRemove.add(node.id);
                    changed = true;
                }
            });
        }
        
        // Remove nodes
        this.nodes = this.nodes.filter(node => !toRemove.has(node.id));
        
        // Remove edges
        this.edges = this.edges.filter(edge => 
            !toRemove.has(edge.source) && !toRemove.has(edge.target)
        );
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

    showLoading(show) {
        const spinner = document.getElementById('loading-spinner');
        if (show) {
            spinner.classList.remove('hidden');
        } else {
            spinner.classList.add('hidden');
        }
    }

    updateStatus(message) {
        // Don't overwrite error messages with "Ready" unless error state is cleared
        if (this.hasError && message === "Ready") {
            return;
        }
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
            // Store error state to prevent automatic reset to "Ready"
            this.hasError = true;
        } else {
            statusText.style.color = '#555';
        }
        
        // Don't auto-reset error messages - they should persist until a new action
        // Success messages during blockchain operations also don't auto-reset
    }

    clearErrorState() {
        // Clear error state and reset status text color when starting a new action
        this.hasError = false;
        const statusText = document.getElementById('status-text');
        statusText.style.color = '#555';
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
        
        // Start auto-save functionality - save graph state every 10 seconds
        this.startAutoSave();
        
        // Start link status checking
        this.startLinkStatusChecking();
    }

    startAutoSave() {

        // Then auto-save every 15 seconds
        setInterval(() => {
            this.autoSaveGraph();
        }, 15000);
    }

    async autoSaveGraph() {
        try {
            // First, update the active node with current seqno before saving
            if (this.activeNodeId) {
                const activeNode = this.nodes.find(n => n.id === this.activeNodeId);
                if (activeNode) {
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
                                // Update the active node's seqno with current blockchain state
                                activeNode.seqno = seqnoData.seqno;
                                activeNode.lastSeqnoUpdate = new Date().toISOString();
                            }
                        }
                    } catch (seqnoError) {
                        console.warn('Could not fetch current seqno during auto-save:', seqnoError);
                    }
                }
            }
            
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
            
            if (response.ok) {
                const data = await response.json();
                if (data.success) {
                    console.log('Graph auto-saved successfully with current seqno');
                } else {
                    console.warn('Auto-save failed:', data.message);
                }
            } else {
                console.warn('Auto-save request failed with status:', response.status);
            }
        } catch (error) {
            console.error('Error during auto-save:', error);
        }
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
                    
                    // Update sync delay - format as seconds with 's' suffix
                    const syncDelay = data.syncDelay !== undefined ? `${data.syncDelay}s` : 'N/A';
                    document.getElementById('current-sync').textContent = syncDelay;
                    
                    // Update running nodes count
                    const runningNodes = data.activeNodes !== undefined ? data.activeNodes : 'N/A';
                    document.getElementById('running-nodes').textContent = runningNodes;
                    
                    // Update active node if it changed
                    this.updateActiveNodeFromVolume(data.id);
                    
                    // Store active nodes count in the active node for future reference
                    if (this.activeNodeId && data.activeNodes !== undefined) {
                        const activeNode = this.nodes.find(n => n.id === this.activeNodeId);
                        if (activeNode) {
                            activeNode.activeNodes = data.activeNodes;
                        }
                    }
                    
                    // Get the actual snapshot name from the active node
                    const activeNode = this.nodes.find(n => n.id === this.activeNodeId);
                    let snapshotName = 'N/A';
                    
                    if (activeNode) {
                        if (activeNode.isRoot) {
                            snapshotName = 'Genesis';
                        } else {
                            snapshotName = activeNode.customName || `S${activeNode.snapshotNumber}`;
                            if (activeNode.type === "instance") {
                                snapshotName += `-${activeNode.instanceNumber || "1"}`;
                            }
                        }
                    } else {
                        // If no active node found but backend says active ID is "0", show Genesis
                        if (data.id === "0") {
                            snapshotName = 'Genesis';
                        }
                        console.warn(`Active node with ID ${this.activeNodeId} not found in nodes array`);
                    }
                    
                    document.getElementById('current-snapshot-name').textContent = snapshotName;
                    
                    // If active node is selected, update the right panel with current seqno
                    if (this.selectedNode && this.selectedNode.id === this.activeNodeId) {
                        this.showNodeInfo(this.selectedNode);
                    }
                } else {
                    document.getElementById('current-seqno').textContent = 'N/A';
                    document.getElementById('current-snapshot-name').textContent = 'N/A';
                    document.getElementById('current-sync').textContent = 'N/A';
                    document.getElementById('running-nodes').textContent = 'N/A';
                }
            } else {
                document.getElementById('current-seqno').textContent = 'N/A';
                document.getElementById('current-snapshot-name').textContent = 'N/A';
                document.getElementById('current-sync').textContent = 'N/A';
                document.getElementById('running-nodes').textContent = 'N/A';
            }
        } catch (error) {
            console.error('Error updating blockchain status:', error);
            document.getElementById('current-seqno').textContent = 'N/A';
            document.getElementById('current-snapshot-name').textContent = 'N/A';
            document.getElementById('current-sync').textContent = 'N/A';
            document.getElementById('running-nodes').textContent = 'N/A';
        }
    }

    updateActiveNodeFromVolume(targetNodeId) {
        if (!targetNodeId) return;
        
        // Don't update active node during operations to prevent re-highlighting
        if (this.isOperationInProgress) {
            return;
        }
        
        // Update active node if it changed
        if (targetNodeId && targetNodeId !== this.activeNodeId) {
            console.log(`Active node changed from ${this.activeNodeId} to ${targetNodeId}`);
            this.activeNodeId = targetNodeId;
            // Re-render nodes to update active styling and arrows
            this.renderNodes();
            this.saveGraph();
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
                        // Blockchain is ready
                        this.isWaitingForBlockchain = false;
                        this.showLoading(false);
                        this.updateStatus("Ready");
                        return;
                    }
                }
                
                // Continue waiting if seqno is still 0 or invalid
                if (this.isWaitingForBlockchain) {
                    setTimeout(checkSeqno, 2000);
                }
            } catch (error) {
                console.error('Error checking seqno:', error);
                if (this.isWaitingForBlockchain) {
                    setTimeout(checkSeqno, 2000);
                }
            }
        };

        checkSeqno();
    }

    async stopBlockchain() {
        // Show confirmation modal
        this.showStopConfirmation();
        return;
    }

    showStopConfirmation() {
        const modal = document.getElementById('stop-confirmation-modal');
        modal.classList.remove('hidden');
    }

    hideStopConfirmation() {
        const modal = document.getElementById('stop-confirmation-modal');
        modal.classList.add('hidden');
    }

    async proceedWithStop() {
        // Clear any previous error state when starting a new action
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Stopping blockchain...");
        
        try {
            const response = await fetch('/stop-blockchain', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                }
            });
            
            const data = await response.json();
            
            if (data.success) {
                this.showMessage(`Blockchain stopped successfully. ${data.stoppedContainers || 0} containers stopped and removed.`, 'success');
                
                // Update the active node to root since blockchain is stopped
                this.activeNodeId = "0";

                this.shouldShowActiveHighlight = false;
                this.renderGraph();
                
                // Save graph and re-render
                await this.saveGraph();
                this.renderGraph();
            } else {
                this.showMessage(`Error stopping blockchain: ${data.message}`, 'error');
            }
        } catch (error) {
            console.error('Error stopping blockchain:', error);
            this.showMessage('Failed to stop blockchain. Please try again.', 'error');
        }
        
        this.showLoading(false);
        this.updateStatus("Ready");
    }

    async startBlockchain() {
        if (!this.selectedNode || !this.selectedNode.isRoot) return;
        
        // Clear any previous error state when starting a new action
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Starting blockchain from Genesis...");
        
        try {
            // Start polling for status updates
            const statusPolling = this.startSnapshotStatusPolling();
            
            const response = await fetch('/restore-snapshot', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    snapshotId: "0",
                    snapshotNumber: "0",
                    nodeType: "root",
                    instanceNumber: null,
                    seqno: 0
                })
            });

            const data = await response.json();
            
            // Stop status polling after getting response
            clearInterval(statusPolling);
            
            // Reset operation flags and restore highlighting
            this.isOperationInProgress = false;
            this.shouldShowActiveHighlight = true;
            
            if (data.success) {
                // Update active node to genesis
                this.activeNodeId = "0";
                
                // Save graph and re-render to show genesis as active
                await this.saveGraph();
                this.renderGraph();

                this.showMessage("Blockchain started from Genesis successfully", 'success');
                
                // After a short delay, show "Starting blockchain..." and wait for valid seqno
                setTimeout(() => {
                    this.isWaitingForBlockchain = true;
                    this.updateStatus("Starting blockchain...");
                    this.waitForValidSeqno();
                }, 2000); // Wait 2 seconds to let user see the success message
            } else {
                this.showMessage(`Error starting blockchain: ${data.message}`, 'error');
                this.showLoading(false);
                this.updateStatus("Not Ready");
            }
        } catch (error) {
            console.error('Error starting blockchain:', error);
            this.showMessage('Failed to start blockchain. Please try again.', 'error');
            this.showLoading(false);
            this.updateStatus("Not Ready");
        }
    }

    unhighlightActiveNode() {
        // Remove active node highlighting by clearing activeNodeId
        this.activeNodeId = null;
        
        // Re-render the graph to remove active styling and arrows
        this.renderGraph();
        
        // Save the updated graph state
        this.saveGraph();
    }

    startLinkStatusChecking() {
        // Define the status element IDs for each port
        this.statusElements = {
            '8080': 'status-8080', // blockchain-explorer
            '8082': 'status-8082', // tonhttpapi (TON Center V2)
            '8081': 'status-8081', // index-api (TON Center V3)
            '88': 'status-88',     // faucet
            '99': 'status-99',      // data-generator
            '8000': 'status-8000'      // file-server
        };

        // Check immediately
        this.checkAllLinkStatuses();

        // Then check every 3 seconds
        setInterval(() => {
            this.checkAllLinkStatuses();
        }, 3000);
    }

    async checkAllLinkStatuses() {
        try {
            // Call the backend health check endpoint
            const response = await fetch('/health-check', {
                method: 'GET',
                headers: {
                    'Content-Type': 'application/json',
                }
            });

            if (response.ok) {
                const data = await response.json();
                if (data.success && data.linkStatuses) {
                    // Update each status element with the result from backend
                    Object.entries(data.linkStatuses).forEach(([port, status]) => {
                        const statusId = this.statusElements[port];
                        if (statusId) {
                            const statusElement = document.getElementById(statusId);
                            if (statusElement) {
                                if (status === 'online') {
                                    statusElement.textContent = 'online';
                                    statusElement.className = 'link-status online';
                                } else {
                                    statusElement.textContent = 'down';
                                    statusElement.className = 'link-status offline';
                                }
                            }
                        }
                    });
                } else {
                    // If backend call failed, mark all as down
                    this.markAllLinksAsDown();
                }
            } else {
                // If backend call failed, mark all as down
                this.markAllLinksAsDown();
            }
        } catch (error) {
            console.error('Error checking link statuses:', error);
            // If backend call failed, mark all as down
            this.markAllLinksAsDown();
        }
    }

    markAllLinksAsDown() {
        Object.values(this.statusElements).forEach(statusId => {
            const statusElement = document.getElementById(statusId);
            if (statusElement) {
                statusElement.textContent = 'down';
                statusElement.className = 'link-status offline';
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

    // Reset functionality methods
    showResetConfirmation() {
        const modal = document.getElementById('reset-confirmation-modal');
        modal.classList.remove('hidden');
    }

    hideResetConfirmation() {
        const modal = document.getElementById('reset-confirmation-modal');
        modal.classList.add('hidden');
    }

    showResetConfiguration() {
        const modal = document.getElementById('reset-config-modal');
        modal.classList.remove('hidden');
    }

    hideResetConfiguration() {
        const modal = document.getElementById('reset-config-modal');
        modal.classList.add('hidden');
    }

    async cleanUp() {
        // Show confirmation modal
        this.showCleanupConfirmation();
        return;
    }

    showCleanupConfirmation() {
        const modal = document.getElementById('cleanup-confirmation-modal');
        modal.classList.remove('hidden');
    }

    hideCleanupConfirmation() {
        const modal = document.getElementById('cleanup-confirmation-modal');
        modal.classList.add('hidden');
    }

    async proceedWithCleanup() {
        // Clear any previous error state when starting a new action
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Cleaning up...");
        
        try {
            const response = await fetch('/clean-up', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                }
            });
            
            const data = await response.json();
            
            if (data.success) {
                this.showMessage('Clean up completed successfully.', 'success');
                
                // Reset the graph to initial state since everything is cleaned up
                this.initializeRootNode();
                await this.saveGraph();
                this.calculateLayout();
                this.renderGraph();

                this.showSpecialCleanupMessage();
            } else {
                this.showMessage(`Error during clean up: ${data.message}`, 'error');
            }
        } catch (error) {
            console.error('Error during clean up:', error);
            this.showMessage('Failed to clean up. Please try again.', 'error');
        }
        
        this.showLoading(false);
        this.updateStatus("Ready");
    }

    showSpecialCleanupMessage() {
        // Create a special modal for the cleanup message
        const modalHtml = `
            <div id="special-cleanup-modal" class="modal-overlay">
                <div class="modal-content">
                    <h3>Clean Up Complete</h3>
                    <p>I can't delete myself. For a complete clean-up,<br>
                    stop and remove container <b>time-machine</b><br>
                    and delete volume <b>mylocalton-docker_shared-data.</b><br>
                    You can also use command:<br><code>docker-compose -f docker-compose.yaml down -v</code></p>
                    <div class="modal-buttons">
                        <button id="special-cleanup-ok" class="modal-btn primary">OK</button>
                    </div>
                </div>
            </div>
        `;
        
        // Add the modal to the body
        document.body.insertAdjacentHTML('beforeend', modalHtml);
        
        // Show the modal
        const modal = document.getElementById('special-cleanup-modal');
        modal.classList.remove('hidden');
        
        // Add event listener for OK button
        document.getElementById('special-cleanup-ok').addEventListener('click', () => {
            modal.remove(); // Remove the modal from DOM
        });
    }

    async submitResetConfiguration() {
        const form = document.getElementById('reset-config-form');
        const formData = new FormData(form);
        
        // Convert form data to object
        const configData = {};
        for (let [key, value] of formData.entries()) {
            configData[key] = value;
        }
        
        this.hideResetConfiguration();
        this.clearErrorState();
        this.showLoading(true);
        this.updateStatus("Resetting blockchain...");
        
        try {
            const response = await fetch('/start-over', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(configData)
            });
            
            const data = await response.json();
            
            if (data.success) {
                // Reset the graph to initial state
                this.initializeRootNode();
                await this.saveGraph();
                this.calculateLayout();
                this.renderGraph();
                
                this.showMessage('Blockchain reset successfully with new configuration', 'success');
                
                // After a short delay, show "Starting blockchain..." and wait for valid seqno
                setTimeout(() => {
                    this.isWaitingForBlockchain = true;
                    this.updateStatus("Starting new blockchain...");
                    this.waitForValidSeqno();
                }, 2000);
            } else {
                this.showMessage(`Error resetting blockchain: ${data.message}`, 'error');
                this.showLoading(false);
                this.updateStatus("Reset failed");
            }
        } catch (error) {
            console.error('Error resetting blockchain:', error);
            this.showMessage('Failed to reset blockchain. Please try again.', 'error');
            this.showLoading(false);
            this.updateStatus("Reset failed");
        }
    }
}

// Initialize the graph when the page loads
document.addEventListener('DOMContentLoaded', () => {
    new BlockchainGraph();
});
