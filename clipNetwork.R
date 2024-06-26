library(sf)
library(dplyr)
library(igraph)

# Because we need to generate the network for all of Victoria, it is necessary
# to clip the network to the study region. We do so by finding all edges with an
# endpoint within the study region, and then finding the largest connected
# component in order to remove any disconnected components arising from the clip

source("clipFunctions.R")







study_region <- st_read("/Users/alan/Projects/JIBE/melbourne/regions/final/region_buffer.sqlite")
nodes <- st_read("/Users/alan/Projects/JIBE/melbourne/network/intermediate/atom_network/network.sqlite", layer="nodes")
edges <- st_read("/Users/alan/Projects/JIBE/melbourne/network/intermediate/atom_network/network.sqlite", layer="links")

# nodes within the study region
nodes_clipped <- nodes %>%
  filter(lengths(st_intersects(., study_region, prepared = TRUE)) > 0)
node_ids <- nodes_clipped$id

# roads that trucks can use
truck_roads <- c("motorway", "motorway_link", "trunk", "trunk_link",
                 "primary", "primary_link", "secondary", "secondary_link",
                 "tertiary", "tertiary_link")

# edges that allow trucks
edges_trucks <- edges %>%
  mutate(is_truck = ifelse(highway%in%truck_roads,1,0) & is_car == 1) %>%
  dplyr::relocate(is_truck,.after=is_car) %>%
  mutate(modes=ifelse(is_truck==1,paste0(modes,",truck"),modes))

# edges that allow trucks or have at least one endpoint within the study region
edges_filtered <- edges_trucks %>%
  filter(is_truck==1 | from_id %in% node_ids | to_id %in% node_ids)



# endpoint nodes of these edges
nodes_filtered <- nodes %>%
  filter(id %in% c(edges_filtered$from_id, edges_filtered$to_id))

# filter nodes and edges to largest connected component
largest_component <- largestConnectedComponent(nodes_filtered,edges_filtered)

# # add is_oneway
# links_tmp <- largest_component[[2]]
# links_directed <- left_join(
#   links_tmp,
#   links_tmp%>%st_drop_geometry()%>%dplyr::select(to_id2=from_id,from_id2=to_id)%>%dplyr::select(from_id=from_id2,to_id=to_id2)%>%mutate(is_oneway=0)%>%distinct(),
#   by=c("from_id","to_id")
# ) %>%
#   mutate(is_oneway=ifelse(is.na(is_oneway),1,0)) %>%
#   st_sf()
# largest_component <- list(largest_component[[1]],links_directed)


# ensure transport is a directed routeable graph for each mode (i.e., connected
# subgraph). The first function ensures a connected directed subgraph and the
# second function ensures a connected subgraph but doesn't consider directionality.
# We car and bike modes are directed, but walk is undirected.

networkNonDisconnected <- largestDirectedNetworkSubgraph(largest_component,'car,bike,truck')
networkConnected <- largestNetworkSubgraph(networkNonDisconnected,'walk')


# export to file
nodes_final <- networkConnected[[1]]
edges_final <- networkConnected[[2]]
st_write(nodes_final, "/Users/alan/Projects/JIBE/melbourne/network/intermediate/clipped_network/melbourneClipped_nodes.sqlite", delete_dsn=T)
st_write(edges_final, "/Users/alan/Projects/JIBE/melbourne/network/intermediate/clipped_network/melbourneClipped_edges.sqlite", delete_dsn=T)
