struct spi_slave *spi_setup_slave(unsigned int busnum, unsigned int cs,
			unsigned int max_hz, unsigned int mode)
{
	return NULL;
}

struct spi_slave *spi_setup_slave_fdt(const void *blob, int slave_node,
				      int spi_node)
{
	return NULL;
}

static int imx8qm_spi_ofdata_to_platdata(struct udevice *dev)
{
	return -ENODEV;
}

static int imx8qm_spi_probe(struct udevice *dev)
{
	return -ENODEV;
}

static int imx8qm_spi_remove(struct udevice *dev)
{
	return -ENODEV;
}

static int imx8qm_spi_claim_bus(struct udevice *dev)
{

	return -ENODEV;
}

static int imx8qm_spi_release_bus(struct udevice *dev)
{

	return -ENODEV;
}

static int imx8qm_spi_xfer(struct udevice *dev, unsigned int bitlen,
			    const void *dout, void *din, unsigned long flags)
{

	return -ENODEV;
}

static int imx8qm_spi_set_speed(struct udevice *dev, uint speed)
{
	return -ENODEV;
}

static int imx8qm_spi_set_mode(struct udevice *dev, uint mode)
{
	return -ENODEV;
}

static int imx8qm_cs_info(struct udevice *bus, uint cs,
			  struct spi_cs_info *info)
{
	return -ENODEV;
}

static const struct dm_spi_ops imx8qm_spi_ops = {
	.claim_bus	= imx8qm_spi_claim_bus,
	.release_bus	= imx8qm_spi_release_bus,
	.xfer		= imx8qm_spi_xfer,
	.set_speed	= imx8qm_spi_set_speed,
	.set_mode	= imx8qm_spi_set_mode,
	.cs_info	= imx8qm_cs_info,
};

static const struct udevice_id imx8qm_spi_ids[] = {
	{ .compatible = "fsl,imx8qm-spi" },
	{ }
};

U_BOOT_DRIVER(imx8qm_spi) = {
	.name	= "imx8qm_spi",
	.id	= UCLASS_SPI,
	.of_match = imx8qm_spi_ids,
	.ops	= &imx8qm_spi_ops,
	.ofdata_to_platdata = imx8qm_spi_ofdata_to_platdata,
	.probe	= imx8qm_spi_probe,
	.remove	= imx8qm_spi_remove,
};

