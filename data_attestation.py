"""
Data Integrity Layer: Multi-Source Attestation Engine
Fetches and verifies data from 5+ independent sources with consensus validation.
"""
import requests
import pandas as pd
import numpy as np
import logging
import json
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
from firebase_admin import firestore
from merkletools import MerkleTools
import os
from dotenv import load_dotenv

load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class DataAttestationEngine:
    """
    Multi-source data verification engine with consensus validation.
    Implements fail-open design: missing data from one source doesn't crash system.
    """
    
    def __init__(self, firestore_client):
        self.firestore = firestore_client
        self.merkle_tools = MerkleTools(hash_type="sha256")
        
        # Configured sources (all free/public APIs)
        self.data_sources = {
            "defillama": {
                "base_url": "https://api.llama.fi",
                "endpoints": {
                    "protocol": "/protocol/{protocol}",
                    "tvl": "/tvl/{protocol}",
                    "pools": "/pools"
                }
            },
            "thegraph": {
                "base_url": "https://api.thegraph.com/subgraphs/name",
                "subgraphs": {
                    "aave": "/aave/protocol-v3-polygon",
                    "uniswap": "/uniswap/uniswap-v3-polygon"
                }
            },
            "polygonscan": {
                "base_url": "https://api.polygonscan.com/api",
                "api_key": os.getenv("POLYGONSCAN_API_KEY", "")
            }
        }
        
        # Cache for performance
        self.cache = {}
        self.cache_ttl = 300  # 5 minutes
        
        # Consensus thresholds
        self.min_consensus_sources = 2  # Require at least 2/3 sources
        self.consensus_threshold = 0.8  # 80% agreement required
        
    def verify_opportunity(self, pool_address: str, protocol_name: str) -> Optional[Dict]:
        """
        Main verification pipeline for a DeFi opportunity.
        Returns verified data dict or None if insufficient consensus.
        """
        logger.info(f"Verifying opportunity: {protocol_name} - {pool_address}")
        
        try:
            # Step 1: Fetch data from all sources
            source_data = self._fetch_all_sources(pool_address, protocol_name)
            
            # Step 2: Apply consensus validation
            consensus_result = self._apply_consensus_validation(source_data)
            
            if not consensus_result["passed"]:
                logger.warning(f"Consensus validation failed for {pool_address}")
                return None
            
            # Step 3: Calculate risk-adjusted score
            risk_score = self._calculate_risk_score(consensus_result["data"])
            
            # Step 4: Build Merkle proof
            merkle_proof = self._build_merkle_proof(consensus_result["data"])
            
            # Step 5: Store attestation in Firestore
            attestation_id = self._store_attestation(
                pool_address, 
                consensus_result["data"], 
                risk_score, 
                merkle_proof
            )
            
            result = {
                "pool_address": pool_address,
                "protocol": protocol_name,
                "verified_data": consensus_result["data"],
                "risk_score": risk_score,
                "merkle_root": merkle_proof["root"],
                "merkle_proof": merkle_proof["proof"],
                "attestation_id": attestation_id,
                "timestamp": datetime.utcnow().isoformat(),
                "sources_used": len(source_data)
            }
            
            logger.info(f"Successfully verified {protocol_name}. Risk score: {risk_score:.2f}")
            return result
            
        except Exception as e:
            logger.error(f"Error verifying opportunity {pool_address}: {str(e)}", exc_info=True)
            # Fail-open: return None but don't crash
            return None
    
    def _fetch_all_sources(self, pool_address: str, protocol_name: str) -> List[Dict]:
        """Fetch data from all configured sources with error isolation."""
        source_data = []
        
        # Source 1: DeFi Llama (TVL and audits)
        try:
            defillama_data = self._fetch_defillama(protocol_name, pool_address)
            if defillama_data:
                source_data.append({"source": "defillama", "data": defillama_data})
        except Exception as e:
            logger.warning(f"DeFi Llama fetch failed: {str(e)}")
        
        # Source 2: The Graph (real-time pool data)
        try:
            graph_data = self._fetch_thegraph(pool_address, protocol_name)
            if graph_data:
                source_data.append({"source": "thegraph", "data": graph_data})
        except Exception as e:
            logger.warning(f"The Graph fetch failed: {str(e)}")
        
        # Source 3: Polygonscan (contract verification)
        try:
            scan_data = self._fetch_polygonscan(pool_address)
            if scan_data:
                source_data.append({"source": "polygonscan", "data": scan_data})
        except Exception as e:
            logger.warning(f"Polygonscan fetch failed: {str(e)}")
        
        # Source 4: Dune Analytics (historical performance)
        try:
            dune_data = self._fetch_dune_analytics(pool_address, protocol_name)
            if dune_data:
                source_data.append({"source": "dune", "data": dune_data})
        except Exception as e:
            logger.warning(f"Dune fetch failed: {str(e)}")
        
        # Source 5: Chainlink Price Feeds (for asset prices)
        try:
            price_data = self._fetch_chainlink_prices()
            if price_data:
                source_data.append({"source": "chainlink", "data": price_data})
        except Exception as e:
            logger.warning(f"Chainlink fetch failed: {str(e)}")
        
        logger.info(f"Retrieved data from {len(source_data)} sources")
        return