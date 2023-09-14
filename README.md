# networkMelbourne
Code for generating the Melbourne transport network

# instructions

Run ```/network/NetworkGeneratorJIBE.R``` to generate the network geometries for Melbourne. Technically it generates a network for all of Victoria so we can make a more accurate freight model. Now adds crossings to the nodes.

```clipNetwork.R``` clips the Victoria-wide network to our study region (Greater Melbourne plus a 10km buffer). We do so by finding all edges with an endpoint within the study region, and then finding the largest connected component in order to remove any disconnected components arising from the clip.

```processNetwork.R``` calculates quietness, positive and negative POIs, whether an edge is part of a highstreet, and Shannon diversity. Main difference is the edge snapping takes place in postgres. This has sped up the process from several days to around 30 seconds

<<<<<<< HEAD
```adjustNetwork.R``` performs the final tweaking to ensure the Melbourne network's attributes are compatible with the Manchester network.
=======
```adjustNetwork.R`` performs the final tweaking to ensure the Melbourne network's attributes are compatible with the Manchester network.
>>>>>>> 0d75494290f990df2eeffe98b3276ce3711da648
