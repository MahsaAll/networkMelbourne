#!/usr/bin/env Rscript

# load libraries and functions --------------------------------------------
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(sf))
suppressPackageStartupMessages(library(RPostgreSQL))
suppressPackageStartupMessages(library(dbscan))
suppressPackageStartupMessages(library(vegan))
options(dplyr.summarise.inform = FALSE) # make dplyr stop blabbing about summarise



# Setup the network database (uses bash) ----------------------------------

# Uncomment and run in the terminal or just use pgadmin

# createdb -U postgres jibenetwork
# psql -U postgres -d jibenetwork -c 'CREATE EXTENSION IF NOT EXISTS postgis'



# Network import ----------------------------------------------------------

# get road network and filter to non PT links
network <- st_read("/Users/alan/Projects/JIBE/melbourne/network/intermediate/clipped_network/melbourneClipped_edges.sqlite") %>% 
  st_as_sf() %>%
  st_set_crs(28355) %>% 
  filter(!modes=="pt")

# We run into trouble if the geometry column is 'GEOMETRY' instead of 'geom'
if('GEOMETRY'%in%colnames(network)) network <- network%>%rename(geom=GEOMETRY)

# Just want a dataframe with the edge ids. Highway and cycleway are needed for
# quietness
output_values <- network %>%
  st_drop_geometry() %>%
  dplyr::select(id,highway,cycleway)

# connect to database
conn = dbConnect(PostgreSQL(), dbname="jibenetwork", user="postgres", password="", host="localhost")

# adding the edges to the database, and generating a spatial index to speed up query
st_write(network, conn, layer="edges")
dbSendQuery(conn,statement="CREATE INDEX edges_gix ON edges USING GIST (geom);")



#  Urban regions ----------------------------------------------------------

# importing urban regions
urban_regions <- st_read("/Users/alan/Projects/JIBE/melbourne/regions/original/urban_regions.sqlite") %>% 
  st_as_sf() %>%
  st_set_crs(28355)

# We run into trouble if the geometry column is 'GEOMETRY' instead of 'geom'
if('GEOMETRY'%in%colnames(urban_regions)) urban_regions <- urban_regions %>% rename(geom=GEOMETRY)

# adding the urban regions to the database, and generating a spatial index to speed up query
st_write(urban_regions, conn, layer="urban_regions")
dbSendQuery(conn,statement="CREATE INDEX urban_regions_gix ON urban_regions USING GIST (geom);")

# get ids of edges within urban regions
dbSendQuery(conn,statement="
  DROP TABLE IF EXISTS urban_edges;
  CREATE TABLE urban_edges AS
  SELECT e.id
  FROM urban_regions AS u,
       edges AS e
  WHERE ST_Intersects(u.geom,e.geom)
;")

urban_edges <- dbGetQuery(conn,"SELECT * FROM urban_edges;") %>% pull(id)

# add urban regions
output_values <- output_values %>% 
  mutate(urban = ifelse(id%in%urban_edges, T, F))



# Negative freight (negpoi_hgv_score) -------------------------------------

# get all bus stops
bus_stops <- st_read("/Users/alan/Projects/JIBE/melbourne/gtfs/final/pt_stops.sqlite") %>%
  filter(type=="bus")  %>%
  mutate(id=row_number())

# We run into trouble if the geometry column is 'GEOMETRY' instead of 'geom'
if('GEOMETRY'%in%colnames(bus_stops)) bus_stops <- bus_stops%>%rename(geom=GEOMETRY)

# add to database and generate spatial index
st_write(bus_stops, conn, layer="bus_stops")
dbSendQuery(conn,statement="CREATE INDEX bus_stops_gix ON bus_stops USING GIST (geom);")

# snap bus stops to nearest edge (within 50m)
dbSendQuery(conn,statement="
  DROP TABLE IF EXISTS bus_stops_snapped;
  CREATE TABLE bus_stops_snapped AS
  SELECT DISTINCT ON (n.id) n.id, e.id AS closest_edge_id
  FROM bus_stops AS n
  JOIN edges AS e ON ST_DWithin(n.geom, e.geom, 50)
  ORDER BY n.id, ST_Distance(n.geom, e.geom)
;")

# ids of edges with a positive poi
bus_stops_snapped <- dbGetQuery(conn,"SELECT * FROM bus_stops_snapped;")

# sum count the number of bus stops for each edge
bus_stops_count <- bus_stops_snapped %>%
  group_by(closest_edge_id) %>%
  summarise(negpoi_hgv_score = n()) %>%
  rename(id=closest_edge_id)

# join to the network
output_values <- output_values %>% 
  left_join(bus_stops_count, by="id")



# POI ---------------------------------------------------------------------

# get all POI
poi_all <- st_read("/Users/alan/Projects/JIBE/melbourne/poi/final/poi.gpkg")

# constrain to Greater Melbourne region 
study_region <- st_read("/Users/alan/Projects/JIBE/melbourne/regions/final/region_buffer.sqlite")
gm_poi <- poi_all %>%
  filter(lengths(st_intersects(., study_region, prepared = TRUE)) > 0)

# # add to database and generate spatial index
# st_write(gm_poi, conn, layer="poi")
# dbSendQuery(conn,statement="CREATE INDEX poi_gix ON poi USING GIST (geom);")



# Highstreet --------------------------------------------------------------

# get highstreet codes 
highstreet <- read.csv("/Users/alan/Projects/JIBE/melbourne/poi/final/highstreet.csv") %>%
  pull(code)
gm_poi_highstreets <- gm_poi %>%
  filter(code %in% highstreet) %>%
  mutate(id=row_number())

# get highstreet POIs coordinates
poi_coors <- gm_poi_highstreets %>%
  st_coordinates()

# get POI clusters
geog_cluster <- dbscan(poi_coors, eps = 150, minPts = 10)['cluster'] %>%
  unlist() %>%
  unname()
gm_poi_highstreets <- gm_poi_highstreets %>%
  mutate(geog_cluster=geog_cluster)

# highstreet clusters
clustered_pois <- gm_poi_highstreets %>%
  filter(geog_cluster > 0)
# non-clusters. Not used for anything
# noise <- gm_poi_highstreets %>%
#   filter(geog_cluster == 0)

# add to database and generate spatial index
st_write(clustered_pois, conn, layer="clustered_pois")
dbSendQuery(conn,statement="CREATE INDEX clustered_pois_gix ON clustered_pois USING GIST (geom);")

# snap pois to nearest edge (within 50m)
dbSendQuery(conn,statement="
  DROP TABLE IF EXISTS clustered_pois_snapped;
  CREATE TABLE clustered_pois_snapped AS
  SELECT DISTINCT ON (n.id) n.id, e.id AS closest_edge_id
  FROM clustered_pois AS n
  JOIN edges AS e ON ST_DWithin(n.geom, e.geom, 50)
  ORDER BY n.id, ST_Distance(n.geom, e.geom)
;")

# ids of edges with a highstreet poi
clustered_pois_snapped <- dbGetQuery(conn,"SELECT * FROM clustered_pois_snapped;") 
highstreet_ids <- clustered_pois_snapped %>%
  pull(closest_edge_id) %>%
  unique()

# add highstreet
output_values <- output_values %>% 
  mutate(highstr = ifelse(id%in%highstreet_ids, "yes", "no"))



# Positive POIs -----------------------------------------------------------

# the positive POI codes
positive <- read.csv("/Users/alan/Projects/JIBE/melbourne/poi/final/positive.csv") %>%
  pull(code)
gm_poi_positive <- gm_poi %>%
  filter(code %in% positive) %>%
  mutate(id=row_number())

# positive codes weights
positive_wgt <- read.csv("/Users/alan/Projects/JIBE/melbourne/poi/final/positive_wgt.csv")

# merge weights
gm_poi_positive <- gm_poi_positive %>%
  inner_join(positive_wgt, by = "code")

# add to database and generate spatial index
st_write(gm_poi_positive, conn, layer="gm_poi_positive")
dbSendQuery(conn,statement="CREATE INDEX gm_poi_positive_gix ON gm_poi_positive USING GIST (geom);")

# snap pois to nearest edge (within 50m)
dbSendQuery(conn,statement="
  DROP TABLE IF EXISTS gm_poi_positive_snapped;
  CREATE TABLE gm_poi_positive_snapped AS
  SELECT DISTINCT ON (n.id) n.id, e.id AS closest_edge_id
  FROM gm_poi_positive AS n
  JOIN edges AS e ON ST_DWithin(n.geom, e.geom, 50)
  ORDER BY n.id, ST_Distance(n.geom, e.geom)
;")

# ids of edges with a positive poi
positive_pois_snapped <- dbGetQuery(conn,"SELECT * FROM gm_poi_positive_snapped;")

# sum the weights of all positive POIs for each edge
posit_count <- gm_poi_positive %>%
  st_drop_geometry() %>%
  inner_join(positive_pois_snapped, by="id") %>%
  group_by(closest_edge_id) %>%
  summarise(positpoi_score = sum(weight, na.rm=T)) %>%
  rename(id=closest_edge_id)

# join to the network
output_values <- output_values %>% 
  left_join(posit_count, by="id")



# Negative POIs -----------------------------------------------------------

# the positive POI codes
negative <- read.csv("/Users/alan/Projects/JIBE/melbourne/poi/final/negative.csv") %>%
  pull(code)
gm_poi_negative <- gm_poi %>%
  filter(code %in% negative) %>%
  mutate(id=row_number())

# negative codes weights
negative_wgt <- read.csv("/Users/alan/Projects/JIBE/melbourne/poi/final/negative_wgt.csv")

# merge weights
gm_poi_negative <- gm_poi_negative %>%
  inner_join(negative_wgt, by = "code")

# add to database and generate spatial index
st_write(gm_poi_negative, conn, layer="gm_poi_negative")
dbSendQuery(conn,statement="CREATE INDEX gm_poi_negative_gix ON gm_poi_negative USING GIST (geom);")

# snap pois to nearest edge (within 50m)
dbSendQuery(conn,statement="
  DROP TABLE IF EXISTS gm_poi_negative_snapped;
  CREATE TABLE gm_poi_negative_snapped AS
  SELECT DISTINCT ON (n.id) n.id, e.id AS closest_edge_id
  FROM gm_poi_negative AS n
  JOIN edges AS e ON ST_DWithin(n.geom, e.geom, 50)
  ORDER BY n.id, ST_Distance(n.geom, e.geom)
;")
# ids of edges with a negative poi
negative_pois_snapped <- dbGetQuery(conn,"SELECT * FROM gm_poi_negative_snapped;")

# sum the weights of all positive POIs for each edge
neg_count <- gm_poi_positive %>%
  st_drop_geometry() %>%
  inner_join(negative_pois_snapped, by="id") %>%
  group_by(closest_edge_id) %>%
  summarise(negpoi_score = sum(weight, na.rm=T)) %>%
  rename(id=closest_edge_id)

# join to the network
output_values <- output_values %>% 
  left_join(neg_count, by="id")



# Shannon -----------------------------------------------------------------

# the count of each highstreet location by category
highstreet_count <- clustered_pois %>%
  st_drop_geometry() %>%
  inner_join(clustered_pois_snapped, by="id") %>%
  group_by(closest_edge_id,code) %>%
  summarise(n = sum(n(), na.rm=T)) %>%
  rename(id=closest_edge_id) %>%
  ungroup() %>%
  mutate(prop = n/sum(n))

# reformat into a matrix for Shannon diversity calculation
count <- as.data.frame.matrix(xtabs(n ~ id + code, highstreet_count), responseName = "id")

# get Shannon Index
shannon <- vegan::diversity(count, index = "shannon") %>% as.data.frame()
shannon$id <- shannon %>% rownames() %>% as.numeric()
colnames(shannon)[1] <- "shannon"

# get Simpson Index
simpson <- vegan::diversity(count, index = "simpson") %>% as.data.frame()
simpson$id <- simpson %>% rownames() %>% as.numeric()
colnames(simpson)[1] <- "simpson"

# join to the network
output_values <- output_values %>% 
  left_join(shannon, by="id") %>% 
  left_join(simpson, by="id")



# Quietness ---------------------------------------------------------------

# read the quietness dataframe. Quietness is assigned based on highway and 
# cycleway category
quietness_index <- read.csv("/Users/alan/Projects/JIBE/melbourne/poi/final/quietness.csv")

# join to the network
output_values <- output_values %>%
  left_join(quietness_index, by = c("highway","cycleway")) %>%
  dplyr::select(-highway,-cycleway)

saveRDS(output_values,"/Users/alan/Projects/JIBE/melbourne/network/intermediate/pois_joined/POIs_joined.rds")


